# frozen_string_literal: true

require "socket"

RSpec.describe HTTP::Client, "reusing a persistent connection" do
  OK = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nok"

  class ResendRecorder < HTTP::Feature
    attr_reader :calls

    def initialize(*)
      super
      @calls = []
    end

    def on_resend(request, error, elapsed)
      @calls << [request.verb, error, elapsed]
    end
  end

  let(:origin) { "http://127.0.0.1:#{@server.addr[1]}" }
  let(:recorder) { ResendRecorder.new }
  let(:client) { HTTP.persistent(origin).timeout(:connect => 2, :write => 2, :read => 2).use(:resend_recorder => recorder) }

  before do
    HTTP::Options.register_feature(:resend_recorder, ResendRecorder)
    @actions  = Queue.new
    @requests = Queue.new
    @accepted = []
    @handlers = []
    @server   = TCPServer.new("127.0.0.1", 0)
    @acceptor = Thread.new { accept_connections }
  end

  after do
    client.close
    @server.close
    @acceptor.join(5)
    @accepted.each { |socket| socket.close unless socket.closed? }
    @handlers.each { |handler| handler.join(5) }
  end

  def accept_connections
    loop do
      socket = @server.accept
      @accepted << socket
      @handlers << Thread.new { serve(socket) }
    end
  rescue IOError
    nil
  end

  # Each request takes the next action; :ok answers and keeps the connection.
  def serve(socket)
    while (request = read_request(socket))
      @requests << request
      break unless respond(socket, next_action)
    end
    socket.close
  rescue IOError, SystemCallError
    nil
  end

  def next_action
    @actions.empty? ? :ok : @actions.pop
  end

  # Returns whether the connection stays open.
  def respond(socket, action)
    case action
    when :ok then socket.write(OK)
    when :big then socket.write("HTTP/1.1 200 OK\r\nContent-Length: 200000\r\n\r\n#{'x' * 200_000}")
    when :ok_then_fin
      socket.write(OK)
      socket.shutdown(Socket::SHUT_WR)
    when :reset then socket.setsockopt(Socket::Option.linger(true, 0))
    end
    %i[ok big ok_then_fin].include?(action)
  end

  def read_request(socket)
    head = socket.gets("\r\n\r\n")
    head + socket.read(head[/^content-length: *(\d+)/i, 1].to_i) if head
  end

  def script(*actions)
    actions.each { |action| @actions << action }
  end

  def wait_for_fin
    socket = client.instance_variable_get(:@connection).instance_variable_get(:@socket).socket
    expect(IO.select([socket], nil, nil, 5)).not_to be_nil
  end

  context "when the server closed the idle connection" do
    it "opens a new one instead of failing the next request" do
      script :ok_then_fin, :ok
      expect(client.get("/").to_s).to eq "ok"
      wait_for_fin

      expect(client.get("/").to_s).to eq "ok"
      expect(@accepted.size).to eq 2
      expect(recorder.calls).to be_empty
    end

    it "sends a POST once" do
      script :ok_then_fin, :ok
      client.post("/", :body => "q=1").to_s
      wait_for_fin

      expect(client.post("/", :body => "q=2").to_s).to eq "ok"
      expect(@requests.size).to eq 2
    end
  end

  context "when the connection is open" do
    it "reuses it" do
      script :ok, :ok
      client.get("/").to_s

      expect(client.get("/").to_s).to eq "ok"
      expect(@accepted.size).to eq 1
    end

    it "still refuses to send on top of an unread body" do
      script :big, :ok
      client.get("/")

      expect { client.get("/") }.to raise_error(HTTP::StateError, /pending/)
    end
  end

  context "when the connection closes under the request" do
    before do
      script :ok, :close, :ok
      client.get("/").to_s
    end

    it "resends a GET once on a new connection" do
      expect(client.get("/").to_s).to eq "ok"
      expect(@accepted.size).to eq 2
      expect(recorder.calls.size).to eq 1

      verb, error, elapsed = recorder.calls.first
      expect(verb).to eq :get
      expect(error.message).to eq "couldn't read response headers"
      expect(elapsed).to be_between(0, 5)
    end

    it "doesn't resend a POST" do
      expect { client.post("/", :body => "q=2") }.to raise_error(HTTP::ConnectionError)
      expect(@requests.size).to eq 2
      expect(recorder.calls).to be_empty
    end

    it "resends a POST marked idempotent" do
      expect(client.post("/", :body => "q=2", :idempotent => true).to_s).to eq "ok"
      expect(@requests.size).to eq 3
    end

    it "doesn't resend an IO body" do
      expect { client.post("/", :body => StringIO.new("q=2"), :idempotent => true) }.
        to raise_error(HTTP::ConnectionError)
      expect(recorder.calls).to be_empty
    end
  end

  context "when the resend fails too" do
    it "raises the second error" do
      script :ok, :close, :close
      client.get("/").to_s

      expect { client.get("/") }.to raise_error(HTTP::ConnectionError)
      expect(@requests.size).to eq 3
      expect(recorder.calls.size).to eq 1
    end
  end

  context "when a reused connection is reset" do
    it "resends a GET" do
      script :ok, :reset, :ok
      client.get("/").to_s

      expect(client.get("/").to_s).to eq "ok"
      expect(recorder.calls.first[1].cause).to be_a(Errno::ECONNRESET)
    end
  end

  context "when a fresh connection is reset" do
    it "doesn't resend" do
      script :reset, :ok

      expect { client.get("/") }.to raise_error(HTTP::ConnectionError)
      expect(@requests.size).to eq 1
    end
  end

  context "without persistence" do
    it "doesn't resend" do
      script :close, :ok

      expect { HTTP.use(:resend_recorder => recorder).get("#{origin}/") }.to raise_error(HTTP::ConnectionError)
      expect(@requests.size).to eq 1
    end
  end
end
