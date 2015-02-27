class BookingTemplate < ActiveRecord::Base
  # Access restrictions
  attr_accessible :title, :code, :amount, :amount_relates_to, :comments, :charge_rate_code

  # Associations
  belongs_to :debit_account, foreign_key: 'debit_account_id', class_name: 'Account'
  attr_accessible :debit_account_id, :debit_account
  belongs_to :credit_account, foreign_key: 'credit_account_id', class_name: 'Account'
  attr_accessible :credit_account_id, :credit_account

  has_many :bookings, through: :line_items

  # Default ordering
  default_scope order(:code)

  # Scopes
  scope :by_type, lambda { |value| where('code LIKE ?', value + ':%') }

  # Standard methods
  include ApplicationHelper
  def to_s(format = :default)
    case format
    when :short
      '%s / %s %s' % [
        debit_account ? debit_account.to_s(:short) : '?',
        credit_account ? credit_account.to_s(:short) : '?',
        amount ? '%0.2f' % amount.to_f : '?'
      ]
    when :long
      '%s an %s %s, %s (%s)' % [
        debit_account ? debit_account.to_s : '?',
        credit_account ? credit_account.to_s : '?',
        amount ? '%0.2f' % amount.to_f : '?',
        title.present? ? title : '?',
        comments.present? ? comments : '?'
      ]
    else
      title
    end
  end

  def amount_to_s
    if amount_relates_to.present?
      return '%.2f%%' % (amount.to_f * 100)
    else
      return currency_fmt(amount)
    end
  end

  # Tagging
  # =======
  if defined?(ActsAsTaggableOn) && ActsAsTaggableOn::Tag.table_exists?
    acts_as_taggable
    attr_accessible :tag_list

    acts_as_taggable_on :include_in_saldo
  end

  def booking_parameters(params = {})
    params = HashWithIndifferentAccess.new(params)

    # Prepare parameters set by template
    booking_params = attributes.reject { |key, _value| !%w(title comments credit_account_id debit_account_id).include?(key) }

    # Calculate amount
    booking_amount = BigDecimal.new(amount.to_s || '0')

    # Lookup reference
    reference = params['reference']
    unless reference
      ref_type = params['reference_type']
      ref_id = params['reference_id']
      if ref_type.present? && ref_id.present?
        reference = ref_type.constantize.find(ref_id)
      end
    end

    person_id = params.delete(:person_id)

    if reference
      # Calculate amount
      booking_amount = amount(reference.value_date, person_id: person_id) if person_id

      case amount_relates_to
        when 'reference_amount'
          booking_amount *= reference.amount unless reference.amount.nil?
        when 'reference_balance'
          booking_amount *= reference.balance unless reference.balance.nil?
        when 'reference_amount_minus_balance'
          booking_amount *= reference.amount - reference.balance unless reference.amount.nil? || reference.balance.nil?
      end
    end

    booking_amount = booking_amount.try(:round, 2)
    booking_params['amount'] = booking_amount

    # Override by passed in parameters
    HashWithIndifferentAccess.new(booking_params.merge!(params))
  end

  # Factory methods
  # ===============
  def build_booking(params = {})
    Booking.new(booking_parameters(params))
  end

  def create_booking(params = {})
    Booking.create(booking_parameters(params))
  end

  # Build booking for template
  #
  # Raises an exception if template for given [code] cannot be found.
  #
  # @param code [String] to lookup template
  # @param params [Hash] parameters to set on the Booking
  # @return [Booking] unsaved Booking
  def self.build_booking(code, params = {})
    template = find_by_code(code)
    fail "BookingTemplate not found for '#{code}'" unless template

    template.build_booking params
  end

  def self.create_booking(code, params = {})
    find_by_code(code).try(:create_booking, params)
  end

  # LineItems
  has_many :line_items

  def build_line_item
    if amount.match(/%/) || amount_relates_to.blank?
      line_item_class = LineItem
    else
      line_item_class = SaldoLineItem
    end

    line_item = line_item_class.new(
      booking_template: self,
      title: title,
      code: code,
      credit_account: credit_account,
      debit_account: debit_account,
      position: position,
      include_in_saldo_list: include_in_saldo_list,
      reference_code: amount_relates_to
    )

    if amount.match(/%/)
      line_item.quantity = '%'
      line_item.times    = amount.delete('%')
      # TODO: hack
      line_item.price    = line_item.price
    elsif amount_relates_to.present?
      line_item.quantity = 'saldo_of'
      # TODO: hack
      line_item.price    = line_item.price
    else
      line_item.quantity = 'x'
      line_item.times    = 1
      line_item.price    = amount
    end

    line_item
  end

  # Importer
  # ========
  attr_accessible :matcher

  def self.import(struct)
    templates = all.inject([]) do |found, template|
      puts 'matcher: ' + template.matcher
      puts 'text: ' + struct.text
      found << template unless Regexp.new(template.matcher).match(struct.text).eql? nil
    end
    puts templates.inspect
  end
end
