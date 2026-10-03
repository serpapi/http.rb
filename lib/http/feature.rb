# frozen_string_literal: true

module HTTP
  class Feature
    def initialize(opts = {}) # rubocop:disable Style/OptionHash
      @opts = opts
    end

    def wrap_request(request)
      request
    end

    def wrap_response(response)
      response
    end

    # Called before Client#perform sends a request once more on a new
    # connection, with the error and seconds spent on the failed attempt.
    def on_resend(_request, _error, _elapsed); end
  end
end

require "http/features/auto_inflate"
require "http/features/auto_deflate"
require "http/features/logging"
require "http/features/instrumentation"
require "http/features/normalize_uri"
