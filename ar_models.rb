module ArModels

  class Provider < ActiveRecord::Base
    self.table_name = 'provider'
    attr_accessible :name
    has_many :urls
  end

  class Color < ActiveRecord::Base
    self.table_name = 'color'
    attr_accessible :name
    has_many :vehicle
  end

  class EquipmentGroup < ActiveRecord::Base
    attr_accessible :name
  end

  class Manufacturer < ActiveRecord::Base
    self.table_name = 'manufacturer'
    attr_accessible :suffix, :name, :description

    has_many :models
  end

  class Model < ActiveRecord::Base
    self.table_name = 'model'
    attr_accessible :manufacturer_id, :name, :trim, :year, :fuel, :price, :hp, :nm, :acceleration,
      :speed, :kml, :width, :length, :height, :load_capacity, :traction_wheel, :canisters, :tow_capacity,
      :tank, :transmission, :transmission_type, :weight, :doors, :created_at, :updated_at, :slug

    belongs_to :manufacturer

    def self.find_by_data(data = {})
      self.where(['name LIKE ? AND fuel=? AND trim LIKE ? AND year=?', data['name'], data['fuel'], data['trim'], data['year']]).first
    end

    def self.create_from_data(data ={})
      return false if  data['trim'].blank? || data['name'].blank? || data['fuel'].blank? || data['year'].blank?

      self.create(
        name:         data['name'],
        trim:         data['trim'],
        year:         data['year'],
        fuel:         data['fuel'],
        price:        data['model_price'],
        hp:           data['hp'],
        nm:           data['nm'],
        acceleration:	data['acceleration'],
        speed:        data['speed'],
        kml:          data['kml'],
        width:        data['width'],
        length:       data['length'],
        height:       data['height'],
        load_capacity:   data['load_capacity'],
        traction_wheel:  data['traction_wheel'],
        canisters:       data['canisters'],
        tow_capacity:    data['tow_capacity'],
        tank:            data['tank'],
        transmission:    data['transmission'],
        transmission_type: data['transmission_type'],
        weight: data['weight'],
        doors: 	data['doors'],
        slug:   "#{data['suffix']} #{data['name']} #{data['trim']}".parameterize
      )
    end
  end

  class Url < ActiveRecord::Base
    self.table_name = 'url'
    attr_accessible :vehicle_id, :url, :visited_at, :ended_at, :created_at, :provider_id

    belongs_to :vehicle
    belongs_to :provider
  end

  class Proxy < ActiveRecord::Base
    self.table_name = 'proxy'
    attr_accessible :ip, :port, :failed, :used_at

    def self.next_proxy(current_proxy)
      return self.first unless current_proxy

      self.where('id > ?', current_proxy.id).limit(1).first
    end
  end

  class Dealer < ActiveRecord::Base
    self.table_name = 'dealer'
    attr_accessible :type, :name, :email, :phone, :phone_alt, :street_name, :number, :letter, :floor, :side, :zip, :web, :fax
    has_one :vehicle
  end

  class UnpermissedImage < ActiveRecord::Base
    self.table_name = 'unpermissed_image'
    attr_accessible :vehicle_id, :url
    belongs_to :vehicle
  end

  class Vehicle < ActiveRecord::Base
    self.table_name = 'vehicle'
    attr_accessible :dealer_id, :model_id, :color_id, :mileage, :service,
      :mileage_at_service, :taxed, :registered_at, :service_at, :model_name, :note, :price

    attr_writer :model_name

    belongs_to :model
    belongs_to :color
    belongs_to :dealer
    has_many :urls
    has_many :vehicle_images
    has_many :vehicle_equipments
    has_many :vehicle_prices
    has_many :unpermissed_images
    has_many :equipments, through: :vehicle_equipments

    def self.create_or_assign_existing(data)
      return nil if  data['suffix'].blank?

      _manufacturer = Manufacturer.find_by_suffix(data['suffix'])
      _manufacturer = Manufacturer.create(suffix: data['suffix'], name: data['suffix']) unless _manufacturer
      _model = _manufacturer.models.find_by_data(data)
      _model = _manufacturer.models.create_from_data(data) unless _model

      return nil unless _model

      _color_id = data['color'].blank? ? nil : (Color.find_or_create_by_name(data['color']).id rescue nil)

      _dealer = Dealer.create(
        type: data['dealer_type'],
        name: data['dealer_name'],
        email: data['email'],
        phone: data['phone'],
        phone_alt: data['phone_alt'],
        street_name: data['street_name'],
        street_number: data['street_number'],
        street_letter: data['street_letter'],
        floor: data['floor'],
        side: data['side'],
        zip: data['zip'],
        web: data['web'],
        fax: data['fax']
      )

      vehicle = self.create(
        dealer_id: _dealer.id,
        model_id: _model.id,
        color_id: _color_id,
        mileage: data['mileage'],
        service: data['service'],
        mileage_at_service: data['mileage_at_service'],
        note: data['note'],
        taxed: data['taxed'],
        registered_at: data['registered_at'],
        service_at: data['service_at'],
        price: data['price']
      )
      _provider = Provider.find_by_name(data['profile'])
      url = vehicle.urls.create(url: data['url'], provider_id: _provider.id)
      LOGGER.debug data

      vehicle.vehicle_prices << VehiclePrice.new(price: data['price'])

      if data['equipment'] && data['equipment'].is_a?(Array)
        data['equipment'].each do |equip|
          unless (value = equip.match(/[.{,}]?\d[.{,}]?/).to_s).blank?
            equip.gsub!(/[.{,}]?\d[.{,}]?/, '').strip!
          end
          _eq = Equipment.where(['name LIKE ?', "%#{equip}%"]).limit(1).first
          unless _eq
            LOGGER.debug "Equipment #{equip} wasn't found, skipping"
            next
          end
          vehicle.vehicle_equipments.create(equipment_id: _eq.id, value: value)
        end
      end

      return url unless data['images'].is_a?(Array)

      data['images'].each do |img_url|
        vehicle.unpermissed_images.create(url: img_url)
      end
      url
    end

  end

  class VehiclePrice < ActiveRecord::Base
    self.table_name = 'vehicle_price'
    attr_accessible :vehicle_id, :price, :created_at, :vehicle
    belongs_to :vehicle#, foreign_key: :vehicle_id
  end

  class VehicleEquipment < ActiveRecord::Base
    self.table_name = 'vehicle_equipment'
    attr_accessible :equipment_id, :vehicle_id, :value
    belongs_to :equipment
    belongs_to :vehicle
  end

  class Equipment < ActiveRecord::Base
    self.table_name = 'equipment'
    attr_accessible :group_id, :name, :description, :equipment_group, :visible
    belongs_to :equipment_group, foreign_key: :group_id
    has_many :vehicle_equipments
    has_many :vehicles, through: :vehicle_equipments

  end
end
