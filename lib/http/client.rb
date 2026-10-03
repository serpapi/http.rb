# frozen_string_literal: true

require "forwardable"

require "http/form_data"
require "http/options"
require "http/feature"
require "http/headers"
require "http/connection"
require "http/redirector"
require "http/uri"

module HTTP
  # Clients make requests and receive responses
  class Client # rubocop:disable Metrics/ClassLength
    extend Forwardable
    include Chainable

    HTTP_OR_HTTPS_RE = %r{^https?://}i

    def initialize(default_options = {})
      @default_options = HTTP::Options.new(default_options)
      @connection = nil
      @reused_connection = false
      @state = :clean
    end

    # Make an HTTP request
    def request(verb, uri, opts = {}) # rubocop:disable Style/OptionHash
      opts = @default_options.merge(opts)
      req = build_request(verb, uri, opts)
      res = perform(req, opts)
      return res unless opts.follow

      Redirector.new(opts.follow).perform(req, res) do |request|
        perform(wrap_request(request, opts), opts)
      end
    end

    # Prepare an HTTP request
    def build_request(verb, uri, opts = {}) # rubocop:disable Style/OptionHash
      opts    = @default_options.merge(opts)
      uri     = make_request_uri(uri, opts)
      headers = make_request_headers(opts)
      body    = make_request_body(opts, headers)

      req = HTTP::Request.new(
        :verb           => verb,
        :uri            => uri,
        :uri_normalizer => opts.feature(:normalize_uri)&.normalizer,
        :proxy          => opts.proxy,
        :headers        => headers,
        :body           => body
      )

      wrap_request(req, opts)
    end

    # @!method persistent?
    #   @see Options#persistent?
    #   @return [Boolean] whenever client is persistent
    def_delegator :default_options, :persistent?

    # Verbs that are safe to send twice (RFC 9110, Section 9.2.2)
    IDEMPOTENT_VERBS = %i[get head put delete options trace].freeze

    # Perform a single (no follow) HTTP request
    #
    # The liveness check in Connection#keep_alive? can't see a close that
    # crosses the request on the wire, or a proxy cutting a tunnel while the
    # origin is still answering. Such a request goes out once more on a new
    # connection, but only when sending it twice is safe. The resend's own
    # failure is final.
    def perform(req, options)
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      perform_once(req, options)
    rescue ConnectionError => e
      raise unless resend?(req, options, e)

      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
      options.features.each_value { |feature| feature.on_resend(req, e, elapsed) }
      perform_once(req, options)
    end

    def close
      @connection.close if @connection
      @connection = nil
      @state = :clean
    end

    private

    def perform_once(req, options)
      verify_connection!(req.uri)

      @state = :dirty

      @connection ||= HTTP::Connection.new(req, options)

      unless @connection.failed_proxy_connect?
        @connection.send_request(req)
        @connection.read_headers!
      end

      res = Response.new(
        :status        => @connection.status_code,
        :version       => @connection.http_version,
        :headers       => @connection.headers,
        :proxy_headers => @connection.proxy_response_headers,
        :connection    => @connection,
        :encoding      => options.encoding,
        :uri           => req.uri
      )

      res = options.features.inject(res) do |response, (_name, feature)|
        feature.wrap_response(response)
      end

      @connection.finish_response if req.verb == :head
      @state = :clean

      res
    rescue
      close
      raise
    end

    # EOF before any response byte counts on any connection. A reset counts
    # only on a connection that had already served a response, as in Go
    # (isReused) and Chromium (IsConnectionReused): on a fresh one it's the
    # answer. An IO body is rewound only after all of it was written, and
    # never a pipe, so only nil and String bodies go again.
    def resend?(req, options, error)
      return false unless options.persistent?
      return false unless IDEMPOTENT_VERBS.include?(req.verb) || options.idempotent
      return false unless req.body.source.nil? || req.body.source.is_a?(String)

      error.message == "couldn't read response headers" ||
        (@reused_connection && error.cause.is_a?(Errno::ECONNRESET))
    end

    def wrap_request(req, opts)
      opts.features.inject(req) do |request, (_name, feature)|
        feature.wrap_request(request)
      end
    end

    # Verify our request isn't going to be made against another URI
    def verify_connection!(uri)
      if default_options.persistent? && uri.origin != default_options.persistent
        raise StateError, "Persistence is enabled for #{default_options.persistent}, but we got #{uri.origin}"
      # We re-create the connection object because we want to let prior requests
      # lazily load the body as long as possible, and this mimics prior functionality.
      elsif @connection && (!@connection.keep_alive? || @connection.expired?)
        close
      # If we get into a bad state (eg, Timeout.timeout ensure being killed)
      # close the connection to prevent potential for mixed responses.
      elsif @state == :dirty
        close
      end

      @reused_connection = !@connection.nil?
    end

    # Merges query params if needed
    #
    # @param [#to_s] uri
    # @return [URI]
    def make_request_uri(uri, opts)
      uri = uri.to_s

      if default_options.persistent? && uri !~ HTTP_OR_HTTPS_RE
        uri = "#{default_options.persistent}#{uri}"
      end

      uri = HTTP::URI.parse uri

      if opts.params && !opts.params.empty?
        uri.query_values = uri.query_values(Array).to_a.concat(opts.params.to_a)
      end

      # Some proxies (seen on WEBRick) fail if URL has
      # empty path (e.g. `http://example.com`) while it's RFC-complaint:
      # http://tools.ietf.org/html/rfc1738#section-3.1
      uri.path = "/" if uri.path.empty?

      uri
    end

    # Creates request headers with cookies (if any) merged in
    def make_request_headers(opts)
      headers = opts.headers

      # Tell the server to keep the conn open
      headers[Headers::CONNECTION] = default_options.persistent? ? Connection::KEEP_ALIVE : Connection::CLOSE

      cookies = opts.cookies.values

      unless cookies.empty?
        cookies = opts.headers.get(Headers::COOKIE).concat(cookies).join("; ")
        headers[Headers::COOKIE] = cookies
      end

      headers
    end

    # Create the request body object to send
    def make_request_body(opts, headers)
      case
      when opts.body
        opts.body
      when opts.form
        form = make_form_data(opts.form)
        headers[Headers::CONTENT_TYPE] ||= form.content_type
        form
      when opts.json
        body = MimeType[:json].encode opts.json
        headers[Headers::CONTENT_TYPE] ||= "application/json; charset=#{body.encoding.name}"
        body
      end
    end

    def make_form_data(form)
      return form if form.is_a? HTTP::FormData::Multipart
      return form if form.is_a? HTTP::FormData::Urlencoded

      HTTP::FormData.create(form)
    end
  end
end
