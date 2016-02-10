DBCONFIG = YAML.load_file('database.yml')
# ActiveRecord::Base.allow_concurrency = true

AGENT = Mechanize.new
AGENT.user_agent_alias = 'Windows Mozilla'
AGENT.read_timeout     = 20  #set the agent time out
AGENT.keep_alive       = false
AGENT.history.max_size = 1
AGENT.follow_redirect  = true

# ActiveRecord::Base.logger = logger

module Parser

  def self.work
    profile_file_name = 'very_cool_cars_ads_website' # set profile you'd like to run script against

    ActiveRecord::Base.establish_connection(DBCONFIG)

    @@config     = YAML.load_file(File.join('profiles', "#{profile_file_name}.yml"))
    @@host       = @@config['setup']['domain']
    @@init_url   = @@config['setup']['init_url']
    profile_name = @@config['setup']['profile_name']

    start_time = Time.now
    puts "Start time: #{start_time}"
    found_links = [] #cache found links here

    current_page = 1
    @@loop_condition = nil
    if @@config['setup']['break_condition']['total_pages_selector']
      total_pages = AGENT.get(current_url(current_page)).search(@@config['setup']['break_condition']['total_pages_selector']).text.to_i
      @@loop_condition = lambda{ current_page <= total_pages}
      puts "Total pages: #{total_pages}"
    elsif @@config['setup']['break_condition']['next_page_selector']
      @@loop_condition = lambda{ !!AGENT.get(current_url(current_page)).search(@@config['setup']['break_condition']['next_page_selector']) }
    end

    while @@loop_condition.call
      puts "Visiting #{current_url(current_page)}"
      tries = 0
      begin
        page = AGENT.get current_url(current_page)
      rescue Exception => e
        if tries >= 2
          tries = 0
          next
        end
        tries += 1
        LOGGER.debug "#{e.class} : #{e.message}"
        retry
      end
      found_captcha = !page.search(@@config['setup']['proxy_force']).text.blank?
      switch_proxy if found_captcha

      car_blocks = page.search(@@config['setup']['item_block_selector'])
      progress = ProgressBar.new("Parsing page #{current_page}", car_blocks.count)
      Parallel.each(car_blocks, :in_processes => 2, :in_threads => car_blocks.count, 
                    :finish => lambda { |i, item| progress.inc }) do |car_block|

        link = car_block.search(@@config['setup']['item_urls_selector']).text
        link = "#{@@host}#{link}" if @@config['setup']['item_urls_type'] == 'path' #skip it if type is "url"
        found_links << link
        data = {}
        ActiveRecord::Base.connection_pool.with_connection do
          #have we already saw this link before?
          _url = ArModels::Url.find_by_url(link)
          if _url
            _url.update_attributes(visited_at: Time.now, ended_at: nil)
            price = car_block.search(@@config['setup']['item_block_price_selector']).text
            price = @@config['setup']['item_block_price_default'] if price.blank?
            unless @@config['setup']['item_block_price_selector_regexp'].blank?
              price = price.match(@@config['setup']['item_block_price_selector_regexp'])[0].to_s rescue price
            end
            unless @@config['setup']['item_block_price_apply_methods'].blank?
              @@config['setup']['item_block_price_apply_methods'].each do |method, params|
                price = price.send(method, *params)
              end
            end
            _url.vehicle.update_attributes(price: price)
            _url.vehicle.vehicle_prices << ArModels::VehiclePrice.new({:price => price})
            found_links << _url.id
            next
          end

          #visiting ad link:
          begin
            link_page = AGENT.get(link)
          rescue Exception => e
            LOGGER.debug "#{e.class} : #{e.message}"
            next
          end
          next unless link_page.code == '200'

          # collecting data from the page
          @@config['data'].each do |key, val|
            if val['selector'].blank?
              next unless val.has_key?('default')
              data[key] = val['default']
              next
            end

            tmp = link_page.search(val['selector']).text
            tmp = CGI::unescapeHTML(tmp)
            tmp = URI.unescape(tmp)

            #regexp processing
            unless val['regexp'].blank?
              regexp_group = val['regexp_group'].to_i rescue 0
              tmp = tmp.match(val['regexp'])[regexp_group].to_s rescue ""
            end
            #boolean condition processing if exists
            unless val['boolean_true_condition'].blank?
              tmp = tmp == val['boolean_true_condition']
            end
            #applying methods:
            unless val['apply_methods'].blank?
              val['apply_methods'].each do |method, params|
                tmp = tmp.send(method, *params)
              end
            end
            #rewriting values:
            unless val['rewrite_values'].blank?
              if val['rewrite_values'].keys.include?(tmp)
                tmp = val['rewrite_values'][tmp]
              end
            end

            #type conversions
            unless tmp.blank?
              case val['type']
              when 'date'
                tmp = Date.parse(tmp)
              when 'integer'
                tmp = tmp.to_i
              when 'float'
                tmp = tmp.to_f
              when 'array'
                tmp = link_page.search(val['selector']).map(&:text)
              end
            end
            tmp = val['default'] if tmp.blank? && !val['default'].blank?

            # images processing
            if key == 'images' && !tmp.blank?
              if val.has_key?('custom_uri_params')
                tmp = tmp.collect{|x| "#{x.split('?')[0]}#{val['custom_uri_params']}" }
              end
              if val['url_type'] == 'path'
                tmp = tmp.collect{|x| @@host + x}
              end
              data[key] = tmp
              next
            end

            #some sites includes model and manufacturer names, we need to get rid of them 
            if key == 'trim' && !val['exclude_name_and_model'].blank?
              tmp = tmp.gsub("#{data['suffix']} #{data['name']} ", '')
            end

            #multipying numeric values 
            unless val['multiplier'].blank? || tmp.blank?
              tmp = (tmp * val['multiplier']).to_i
            end

            #force null if value isn't a valid digit
            if val['digit_or_null']
              tmp = tmp =~ /\d{1,}/ && tmp
            end

            unless val['array_separated_with'].blank?
              tmp = tmp.split(val['array_separated_with'])
            end

            tmp = nil if tmp.blank?
            data[key] = tmp
          end
          puts

          url = Vehicle.create_or_assign_existing(data.merge({'url' => link, 'profile' => profile_name}))
          next unless url
          found_links << url.id
        end
      end
      progress.finish

      current_page += 1
      # break #uncomment for test mode
    end

    time_spent = ((Time.now - start_time) / 60).round()
    puts "Time spent: #{time_spent} (min)"
    puts "updating the links we haven't found on this pass..."

    #marking ads that were not found at this pass as ended:
    profile = ArModels::Provider.find_by_name(profile_name)
    unfound_links_ids = profile.urls.all(select: :id).map(&:id) - found_links
    ArModels::Url.where('id IN (?)', unfound_links_ids).update_all(ended_at: Time.now)
    puts "<=== done"
  end


  def self.switch_proxy
    @@current_proxy = Proxy.next_proxy(@@current_proxy)
    AGENT.set_proxy @@current_proxy.ip, @@current_proxy.port
  end


  def self.current_url(page)
    "#{@@init_url}#{@@config['setup']['pagination_param']}".gsub('<<<page>>>', page.to_s)
  end

end
