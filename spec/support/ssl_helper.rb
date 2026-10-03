# frozen_string_literal: true

require "pathname"

require "openssl"

# Version 3 certificates that current OpenSSL accepts, valid from an hour ago
# in UTC so local time zones can't make them "not yet valid".
module SSLHelper
  CERTS_PATH = Pathname.new File.expand_path("../../../tmp/certs", __FILE__)

  module Signing
    def build(subject, issuer, key, issuer_key, serial)
      cert            = OpenSSL::X509::Certificate.new
      cert.version    = 2
      cert.serial     = serial
      cert.subject    = OpenSSL::X509::Name.parse(subject)
      cert.issuer     = issuer || cert.subject
      cert.public_key = key.public_key
      cert.not_before = Time.now.utc - 3600
      cert.not_after  = Time.now.utc + 86_400

      extensions = OpenSSL::X509::ExtensionFactory.new
      extensions.subject_certificate = cert
      extensions.issuer_certificate  = @issuer_cert || cert
      yield cert, extensions
      cert.sign(issuer_key, OpenSSL::Digest.new("SHA256"))
    end
  end

  class RootCertificate
    include Signing

    attr_reader :cert, :key

    def initialize
      @key  = OpenSSL::PKey::RSA.new(2048)
      @cert = build("/CN=honestachmed.com", nil, @key, @key, 1) do |cert, ext|
        cert.add_extension ext.create_extension("basicConstraints", "CA:TRUE", true)
        cert.add_extension ext.create_extension("keyUsage", "keyCertSign,cRLSign", true)
        cert.add_extension ext.create_extension("subjectKeyIdentifier", "hash")
      end
    end

    def file
      return @file if defined? @file

      CERTS_PATH.mkpath

      cert_file = CERTS_PATH.join("ca.crt")
      cert_file.open("w") { |io| io << cert.to_pem }

      @file = cert_file.to_s
    end
  end

  class ChildCertificate
    include Signing

    attr_reader :cert, :key

    def initialize(parent)
      @issuer_cert = parent.cert
      @key  = OpenSSL::PKey::RSA.new(2048)
      @cert = build("/CN=127.0.0.1", parent.cert.subject, @key, parent.key, Random.rand(1 << 64)) do |cert, ext|
        cert.add_extension ext.create_extension("basicConstraints", "CA:FALSE", true)
        cert.add_extension ext.create_extension("keyUsage", "digitalSignature,keyEncipherment", true)
        cert.add_extension ext.create_extension("subjectAltName", "IP:127.0.0.1")
        cert.add_extension ext.create_extension("authorityKeyIdentifier", "keyid:always")
      end
    end
  end

  class << self
    def server_context
      context = OpenSSL::SSL::SSLContext.new

      context.verify_mode = OpenSSL::SSL::VERIFY_PEER
      context.key         = server_cert.key
      context.cert        = server_cert.cert
      context.ca_file     = ca.file

      context
    end

    def client_context
      context = OpenSSL::SSL::SSLContext.new

      context.options     = OpenSSL::SSL::SSLContext::DEFAULT_PARAMS[:options]
      context.verify_mode = OpenSSL::SSL::VERIFY_PEER
      context.key         = client_cert.key
      context.cert        = client_cert.cert
      context.ca_file     = ca.file

      context
    end

    def client_params
      {
        :key => client_cert.key,
        :cert => client_cert.cert,
        :ca_file => ca.file
      }
    end

    %w[server client].each do |side|
      class_eval <<-RUBY, __FILE__, __LINE__
        def #{side}_cert
          @#{side}_cert ||= ChildCertificate.new ca
        end
      RUBY
    end

    def ca
      @ca ||= RootCertificate.new
    end
  end
end
