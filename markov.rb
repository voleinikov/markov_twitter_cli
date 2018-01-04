require "./secrets.rb"
require "json"
require "twitter"
require "digest"

# This class contains a very simple generator algorithm for a  
# first order makov chain from string tokens split on spaces.  
# It returns a ruby hash with token keys mapped to a frequency array  
# of tokens that followed them.
# 
# Example:
# Input: "The fox jumped over the dog.""
# Output: {
#   "**START**" => ["the"],
#   "the"       => ["fox", "dog"],
#   "fox"       => ["jumped"],
#   "jumped"    => ["over"],
#   "over"      => ["the"],
#   "dog"       => ["**END**"]
# }
# 
# To generate a new sentence from my chain, I begin with the 
# start token and grab a random token from its frequency array using 
# ruby's simple Array#sample method, and keep doing this until I hit 
# an end token.  

class MarkovChain 

  START_TOKEN = "**START**"
  END_TOKEN = "**END**"
  
  class << self 
    def find_cached_json fname
      path = "./#{fname}.json"
      if File.exist?(path)
        f = File.read(path)
        pmatrix = JSON.parse(f)
        self.new pmatrix
      else
        false
      end
    end
  end

  def initialize pmatrix = nil 
    @pmatrix = pmatrix ? pmatrix : Hash.new { |h, k| h[k] = [] }
  end

  # Any length string can be added to the probability matrix
  def add s
    add_to_probability_matrix s
  end

  def cache_to_json fname
    File.open("./#{fname}.json", "w") do |f|
      f.write(@pmatrix.to_json)
    end
  end

  def generate_new_sentence
    seed = START_TOKEN
    word_list = []

    until seed == END_TOKEN
      seed = @pmatrix[seed].sample
      word_list.push(seed) unless seed == END_TOKEN
    end

    word_list.join(" ")
  end

private


  def add_to_probability_matrix s
    token_array = tokenize(sanitize s).unshift(START_TOKEN).push(END_TOKEN)
    token_pair_array = []
  
    for i in 0..(token_array.length - 2)
      token_pair_array.push([token_array[i], token_array[i+1]])
    end

    token_pair_array.each do |pair_arr|
       @pmatrix[pair_arr[0]].push(pair_arr[1])
    end
  end

  # Get rid of URLs and non-ASCII characters. These are dirty tweets after all. 
  # We will keep @mentions and hash tags though. 
  def sanitize unsanitized 
    encoding_options = {
      :invalid           => :replace,  # Replace invalid byte sequences
      :undef             => :replace,  # Replace anything not defined in ASCII
      :replace           => '',        # Use a blank for those replacements
      :universal_newline => true       # Always break lines with \n
    }

    url_re = /(?:f|ht)tps?:\/[^\s]+/

    unsanitized.encode(Encoding.find('ASCII'), encoding_options).gsub('&amp;', '').gsub(url_re, '').strip
  end

  # A very simple tokenization scheme based on spaces.
  def tokenize s 
    s.split(/\s/)
  end
end


# The CLI class manages state and includes a twitter client created with 
# the help of the ruby twitter client library sferik/twitter
class MarkovTwitterCLI
  TWT_CLIENT_OPTS = {
    tweet_mode: "extended", 
    count: 150, 
    exclude_replies: true, 
    include_rts: false
  }

  def initialize
    @twitter_client = Twitter::REST::Client.new do |config|
      config.consumer_key = CONSUMER_KEY
      config.consumer_secret = CONSUMER_SECRET
      config.access_token = ACCESS_TOKEN
      config.access_token_secret = ACCESS_TOKEN_SECRET 
    end

    # Initialize Markov Twitter Client with currently authorized user as the 
    # initial markov seed.
    @current_markov_seed = @twitter_client.user.name

    # Don't generate a markov chain right away
    @current_markov_chain = nil 
    @caching = false
  end

  def run_loop
    while true
      print_menu
      selection = gets.chomp.upcase

      case selection
        when "A"
          change_markov_seed_user
        when "B"
          print_user_timeline
        when "C"
          generate_chain_or_tweet
        when "D"
          turn_caching_on_off
        when "Z"
          show_markov_chain_data
        when "E"
          Kernel::exit
      end
      puts ""
    end
  end

private 


  def print_menu
    puts "*"*50
    puts "Current Markov Seed: #{@current_markov_seed}"
    puts "Caching: #{@caching ? 'ON' : 'OFF'}"
    puts "*"*50
    puts ""

    puts "Please select letter of what you would like to do:"
    puts "A.  Change Markov Seed User"
    puts "B.  View Seed Users Latest Tweets" 
    puts "C.  #{@current_markov_chain ? 'Generate Tweet' : 'Generate Markov Chain'}"
    puts "D.  Turn #{@caching ? 'Off' : 'On'} Caching"
    puts "E.  Exit"
    puts "Z.  Show Markov Chain Data"
  end

  def change_markov_seed_user
    puts "Who do you want to mimic?"
    @current_markov_seed = gets.chomp
    @current_markov_chain = nil
    puts "New markov seed: #{@current_markov_seed}"
  end


  def print_user_timeline
    @twitter_client.user_timeline(@current_markov_seed, TWT_CLIENT_OPTS).each do |tweet|
      puts_with_newline "Created On: #{tweet.created_at}\t Text: #{tweet.attrs[:full_text]}"
    end
  end

  def generate_chain_or_tweet
    if @current_markov_chain
      generate_fake_tweet
    else
      generate_markov_chain
    end
  end

  def generate_fake_tweet
    puts_with_newline "Generating..."
    sleep 1
    puts "@#{@current_markov_seed} Tweets..."
    puts @current_markov_chain.generate_new_sentence
  end

  def generate_markov_chain
    if @caching
      find_or_generate_chain
    else
      generate_chain
    end
  end

  def find_or_generate_chain
    puts_with_newline "Searching for cached chain for user #{@current_markov_seed}"
    @current_markov_chain = MarkovChain.find_cached_json cached_filename 

    if !@current_markov_chain 
      puts_with_newline "No cache hit..."
      generate_chain
      @current_markov_chain.cache_to_json cached_filename
    else
      puts_with_newline "Found it!"
    end
  end

  def generate_chain
    puts_with_newline "Generating..."
    @current_markov_chain = MarkovChain.new
    @twitter_client.user_timeline(@current_markov_seed, TWT_CLIENT_OPTS).each do |tweet|
      @current_markov_chain.add(tweet.attrs[:full_text])
    end
  end

  # Hash the user's twitter username for a consistent filename and a bit
  # of privacy -- no filenames with twitter usernames lying around.
  def cached_filename 
    raw_filename = "#{@current_markov_seed}_markov_chain"
    saved_filename = Digest::MD5.hexdigest(raw_filename)
  end

  # This method is a convenience for debugging purposes and would be removed in 
  # any kind of production release.
  def show_markov_chain_data
    puts @current_markov_chain.instance_variable_get('@pmatrix').inspect if @current_markov_chain
  end

  def turn_caching_on_off
    @caching = !@caching
  end

  def puts_with_newline str
    puts str
    puts ""
  end
end

# Test suite
cli = MarkovTwitterCLI.new()
cli.run_loop