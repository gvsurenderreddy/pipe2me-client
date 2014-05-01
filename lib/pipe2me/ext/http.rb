require "net/http"
require "net/https"
require "ostruct"
require "forwardable"

# The HTTP module implements a simple wrapper around Net::HTTP, intended to
# ease the pain of dealing with HTTP requests.
module Pipe2me::HTTP
  extend self

  def self.enable_insecure_mode
    UI.error "Enabling insecure_mode"
    @insecure_mode = true
  end

  def self.insecure_mode?
    !! @insecure_mode
  end

  # Error to be raised when maximum number of redirections is reached.
  class RedirectionLimit < RuntimeError; end

  # Base class for HTTP related errors.
  class Error < RuntimeError

    # The response object (of class HTTP::Response).
    attr_reader :response

    def initialize(response) #:nodoc:
      @response = response
    end

    extend Forwardable
    delegate [ :code, :url ] => :@response

    def message #:nodoc:
      "#{url}: #{code} #{@response[0..120]} (#{@response.response.class})"
    end
  end

  # Raised when a server responded with an error 5xx.
  class ServerError < Error; end

  # Raised when a server responded with an error 4xx.
  class ResourceNotFound < Error; end

  # -- configuration

  @@config = OpenStruct.new

  # The configuration object. It supports the following entries:
  # - <tt>config.headers</tt>: default headers to use when doing HTTP requests. Default: "Ruby HTTP client/1.0"
  # - <tt>config.max_redirections</tt>: the number of maximum redirections to follow. Default: 10
  #
  # To adjust the configuration change these objects, like so:
  #
  #   HTTP.config.headers =  { "User-Agent" => "My awesome thingy/1.0" }
  def config
    @@config
  end

  # A default set of headers
  config.headers = {
    "User-Agent" => "Ruby HTTP client/1.0"
  }

  # The default number of max redirections.
  config.max_redirections = 10

  # -- return types

  # The HTTP::Response class works like a string, but contains extra "attributes"
  # status and headers, which return the response status and response headers.
  class Response < String

    # The URL of the final request.
    attr_reader :url

    # The URL of the original request.
    attr_reader :original_url

    # The response object.
    attr_reader :response

    def initialize(response, url, original_url) #:nodoc:
      @response, @url, @original_url = response, url, original_url
      super(response.body || "")
    end

    # returns true if the status is in the 2xx range.
    def valid?
      (200..299).include? status
    end

    # returns the response object itself, if it is valid (i.e. has a 2XX status),
    # or raise an Error.
    def validate!
      return self if valid?

      case status
      when 400..499 then raise ResourceNotFound, self
      when 500..599 then raise ServerError, self
      else raise Error, self
      end
    end

    # returns the HTTP status code, as an Integer.
    def code
      @response.code.to_i
    end

    alias :status :code

    # returns all headers.
    def headers
      @headers ||= {}.tap do |h|
        @response.each_header do |key, value|
          h[key] = value
        end
      end
    end

    def content_type
      headers["content-type"]
    end

    def parse
      case content_type
      when /application\/json/
        require "json" unless defined?(JSON)
        JSON.parse(self)
      else
        UI.warn "#{url}: Cannot parse #{content_type.inspect} response"
        self
      end
    end
  end

  # -- do requests ----------------------------------------------------

  # runs a get request and return a HTTP::Response object.
  def get(url, headers = {})
    do_request Net::HTTP::Get, url, headers
  end

  # runs a post request and return a HTTP::Response object.
  def post(url, body, headers = {})
    do_request Net::HTTP::Post, url, headers, body
  end

  private

  def method_missing(sym, *args, &block)
    case sym.to_s
    when /^(.*)\!$/
      response = send $1, *args, &block
      response.validate!
    when /^(.*)\?$/
      response = send $1, *args, &block
      response if response.valid?
    else
      super
    end
  end

  #:nodoc:
  def do_request(verb, uri, headers, body = nil)
    UI.benchmark :info, "[#{verb.name.gsub(/.*::/, "").upcase}] #{uri}" do
      do_raw_request verb, uri, headers, body, config.max_redirections, uri, Net::HTTP::Get
    end

  rescue ::OpenSSL::SSL::SSLError
    UI.error "#{uri}: SSL connection failed"
    UI.error "#{uri}: Note: you may use the -k/--insecure flag to disable certificate validation"
    raise $!
  rescue
    UI.error "#{uri} #{$!.class} #{$!}"
    raise $!
  end

  def do_raw_request(verb, uri, headers, body, max_redirections, original_url, redirection_verb = Net::HTTP::Get)
    # merge default headers
    headers = config.headers.merge(headers)

    # create connection

    uri = URI.parse(uri) if uri.is_a?(String)

    default_port = uri.scheme == "https" ? 443 : 80
    http = Net::HTTP.new(uri.host, uri.port || default_port)
    if uri.scheme == "https"
      http.use_ssl = true

      if insecure_mode?
        UI.warn "Disabling certificate validation."
        http.verify_mode = ::OpenSSL::SSL::VERIFY_NONE
      end
    end

    # create request and get response

    request = verb.new(uri.request_uri)
    request.initialize_http_header headers

    if verb.const_get "REQUEST_HAS_BODY"
      case body
      when String
        request.body = body
      when Hash
        request.form_data = body
      when nil
      else
        raise ArgumentError, "Unsupported body of class #{body.class.name}"
      end
    end


    request.basic_auth(r.user, r.password) if uri.user && uri.password
    response = http.request(request)

    # follow redirection, if needed

    case response
    when Net::HTTPRedirection
      # Note: we always follow the redirect using a GET. This seems to violate parts of
      # RFC 2616, but sadly seems the best default behaviour, as is implemented that way
      # in many clients..
      raise RedirectionLimit.new(original_url) if max_redirections <= 0
      return do_raw_request redirection_verb, response["Location"], headers, max_redirections-1, original_url, redirection_verb
    else
      Response.new(response, uri.to_s, original_url)
    end
  end
end
