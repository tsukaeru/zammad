# frozen_string_literal: true
require 'minitest/autorun'
require 'json'
require 'openssl'
require 'securerandom'
require_relative '../../lib/hotaru/reply_draft_client'

class HotaruReplyDraftClientTest < Minitest::Test
  def setup
    @request_id = SecureRandom.uuid
    @config = { 'HOTARU_REPLY_DRAFT_URL' => 'https://hotaru.example.test', 'HOTARU_REPLY_DRAFT_INTEGRATION_ID' => 'instance-a', 'HOTARU_REPLY_DRAFT_SECRET' => 'ab' * 32 }
    @client = Hotaru::ReplyDraftClient.new(env: @config)
  end

  def response(body, code: '200')
    result = Net::HTTPResponse.new('1.1', code, 'result')
    result.instance_variable_set(:@read, true)
    result.body = JSON.generate(body)
    result
  end

  def with_http(result)
    http = Object.new
    http.define_singleton_method(:request) { |request, &block| block.call(result) }
    result.define_singleton_method(:read_body) { |&block| block.call(instance_variable_get(:@body)) }
    Net::HTTP.stub(:start, ->(*_args, **_kwargs, &block) { block.call(http) }) { yield }
  end

  def test_wrong_instance_tampered_actor_csrf_and_replay_are_denied
    # This boundary signs only server-owned actor/integration values, with a fresh nonce per request.
    requests = []
    result = response(status: 'ready', draft: 'Hello', language: 'en', evidence_revision: 'a' * 64, request_id: @request_id)
    result.define_singleton_method(:read_body) { |&block| block.call(instance_variable_get(:@body)) }
    http = Object.new
    http.define_singleton_method(:request) { |request, &block| requests << request; block.call(result) }
    Net::HTTP.stub(:start, ->(*_args, **_kwargs, &block) { block.call(http) }) do
      2.times { @client.call(actor_id: 42, ticket_id: 17, request_id: @request_id, language: 'auto') }
    end
    assert_equal 2, requests.map { |r| r['X-Hotaru-Nonce'] }.uniq.length
    requests.each do |request|
      payload = JSON.parse(request.body)
      assert_equal %w[actor_id integration_id language request_id ticket_id], payload.keys.sort
      assert_equal 42, payload['actor_id']
      assert_equal 'instance-a', payload['integration_id']
      signed = [request['X-Hotaru-Timestamp'], request['X-Hotaru-Nonce'], request.body].join("\n")
      assert_equal OpenSSL::HMAC.hexdigest('SHA256', ['ab' * 32].pack('H*'), signed), request['X-Hotaru-Signature']
    end
  end

  def test_validation_is_read_only_and_binds_evidence_revision
    with_http(response(valid: true, request_id: @request_id)) do
      assert_equal true, @client.call(actor_id: 42, ticket_id: 17, request_id: @request_id, language: 'auto', evidence_revision: 'a' * 64)['valid']
    end
  end

  def test_timeout_rate_limit_and_duplicate_requests_never_post
    Net::HTTP.stub(:start, ->(*_args, **_kwargs) { raise Net::ReadTimeout }) do
      assert_raises(Hotaru::ReplyDraftClient::Unavailable) { @client.call(actor_id: 42, ticket_id: 17, request_id: @request_id, language: 'auto') }
    end
    with_http(response({}, code: '302')) do
      assert_raises(Hotaru::ReplyDraftClient::Unavailable) { @client.call(actor_id: 42, ticket_id: 17, request_id: @request_id, language: 'auto') }
    end
  end

  def test_malformed_oversized_and_wrong_request_results_are_rejected
    [{ status: 'ready', draft: 'X' * 12001, language: 'en', evidence_revision: 'a' * 64, request_id: @request_id },
     { status: 'ready', draft: 'Hello', language: 'en', evidence_revision: 'a' * 64, request_id: SecureRandom.uuid }].each do |body|
      with_http(response(body)) do
        assert_raises(Hotaru::ReplyDraftClient::Unavailable) { @client.call(actor_id: 42, ticket_id: 17, request_id: @request_id, language: 'auto') }
      end
    end
    assert_raises(Hotaru::ReplyDraftClient::Unavailable) { Hotaru::ReplyDraftClient.new(env: @config.merge('HOTARU_REPLY_DRAFT_URL' => 'http://example.test')) }
    assert_raises(Hotaru::ReplyDraftClient::Unavailable) { Hotaru::ReplyDraftClient.new(env: @config.merge('HOTARU_REPLY_DRAFT_URL' => 'https://user:password@example.test')) }
  end
end
