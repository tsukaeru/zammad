# Copyright (C) 2026 Tsukaeru.
# frozen_string_literal: true

require 'json'
require 'net/http'
require 'openssl'
require 'securerandom'
require 'uri'

module Hotaru
  class ReplyDraftClient
    class Unavailable < StandardError; end

    UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
    REVISION = /\A[0-9a-f]{64}\z/
    LANGUAGES = %w[auto en ja id].freeze

    def initialize(env: ENV)
      @origin = URI.parse(env.fetch('HOTARU_REPLY_DRAFT_URL', ''))
      @integration_id = env.fetch('HOTARU_REPLY_DRAFT_INTEGRATION_ID', '')
      secret = env.fetch('HOTARU_REPLY_DRAFT_SECRET', '')
      raise Unavailable if @origin.scheme != 'https' || @origin.host.to_s.empty? || @origin.userinfo || @origin.query || @origin.fragment || !['', '/'].include?(@origin.path)
      raise Unavailable if !/\A[a-zA-Z0-9_-]{1,64}\z/.match?(@integration_id) || !REVISION.match?(secret)

      @secret = [secret].pack('H*')
    rescue URI::InvalidURIError
      raise Unavailable
    end

    def call(actor_id:, ticket_id:, request_id:, language:, evidence_revision: nil)
      raise Unavailable if !actor_id.is_a?(Integer) || actor_id <= 0 || !ticket_id.is_a?(Integer) || ticket_id <= 0
      raise Unavailable if !UUID.match?(request_id.to_s) || !LANGUAGES.include?(language)
      raise Unavailable if evidence_revision && !REVISION.match?(evidence_revision.to_s)

      payload = { integration_id: @integration_id, actor_id: actor_id, ticket_id: ticket_id, request_id: request_id, language: language }
      payload[:evidence_revision] = evidence_revision if evidence_revision
      uri = @origin.dup
      uri.path = evidence_revision ? '/v1/zammad/reply-drafts/validate' : '/v1/zammad/reply-drafts'
      body = JSON.generate(payload)
      timestamp = Time.now.to_i.to_s
      nonce = SecureRandom.hex(16)
      request = Net::HTTP::Post.new(uri.request_uri)
      request['Content-Type'] = 'application/json'
      request['Accept'] = 'application/json'
      request['X-Hotaru-Timestamp'] = timestamp
      request['X-Hotaru-Nonce'] = nonce
      request['X-Hotaru-Signature'] = OpenSSL::HMAC.hexdigest('SHA256', @secret, [timestamp, nonce, body].join("\n"))
      request.body = body
      raw = +''
      # No redirects, retries, cookies or proxy credentials. HTTPS verifies the configured server.
      Timeout.timeout(48) do
        Net::HTTP.start(uri.host, uri.port, nil, use_ssl: true, open_timeout: 3, read_timeout: 45, write_timeout: 3) do |http|
          http.request(request) do |response|
            raise Unavailable if response.code != '200'

            response.read_body do |chunk|
              raw << chunk
              raise Unavailable if raw.bytesize > 64000
            end
          end
        end
      end
      result = JSON.parse(raw)
      validate_result!(result, request_id, !evidence_revision.nil?)
      result
    rescue JSON::ParserError, IOError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError
      raise Unavailable
    end

    private

    def validate_result!(result, request_id, validation)
      raise Unavailable if !result.is_a?(Hash) || result['request_id'] != request_id
      if validation
        raise Unavailable if ![true, false].include?(result['valid']) || result.keys.sort != %w[request_id valid]
        return
      end
      raise Unavailable if result.keys.sort != %w[draft evidence_revision language request_id status]
      raise Unavailable if !%w[ready none].include?(result['status']) || !%w[en ja id].include?(result['language'])
      raise Unavailable if !result['draft'].is_a?(String) || result['draft'].length > 12000 || !REVISION.match?(result['evidence_revision'].to_s)
      raise Unavailable if result['status'] == 'ready' && result['draft'].strip.empty?
    end
  end
end
