require 'sinatra'
require 'stripe'
require 'dotenv'
require 'json'
require 'encrypted_cookie'

$stdout.sync = true # Get puts to show up in heroku logs

Dotenv.load
Stripe.api_key = ENV['STRIPE_PROD_SECRET_KEY']

use Rack::Session::EncryptedCookie,
  :secret => ENV['STRIPE_PROD_SECRET_KEY'] # Actually use something secret here!

def log_info(message)
  puts "\n" + message + "\n\n"
  return message
end

get '/' do
  status 200
  return log_info("Great, your backend is set up. Now you can configure the Stripe example apps to point here.")
end


post '/ephemeral_keys' do
  authenticate!
  
  begin
    key = Stripe::EphemeralKey.create(
      {customer: @customer.id},
      {stripe_version: params["api_version"]}
    )
  rescue Stripe::StripeError => e
    status 402
    return log_info("Error creating ephemeral key: #{e.message}")
  end

  content_type :json
  status 200
  key.to_json
end

def authenticate!
  # This code simulates "loading the Stripe customer for your current session".
  # Your own logic will likely look very different.
  return @customer if @customer
  if session.has_key?(:customer_id)
    customer_id = session[:customer_id]
    begin
      @customer = Stripe::Customer.retrieve(customer_id)
    rescue Stripe::InvalidRequestError
    end
  else
    default_customer_id = ENV['DEFAULT_CUSTOMER_ID']
    if default_customer_id
      @customer = Stripe::Customer.retrieve(default_customer_id)
    else
      begin
        @customer = create_customer()

        if (Stripe.api_key.start_with?('sk_test_'))
          # only attach test cards in testmode
          attach_customer_test_cards()
        end
      rescue Stripe::InvalidRequestError
      end
    end
    session[:customer_id] = @customer.id
  end
  @customer
end

def create_customer
  Stripe::Customer.create(
    :description => 'Bloomen iOS Customer',
    :metadata => {
      # Add our application's customer id for this Customer, so it'll be easier to look up
      :my_customer_id => 'Refer to Firebase',
    },
  )
end

def attach_customer_test_cards
  # Attach some test cards to the customer for testing convenience.
  # See https://stripe.com/docs/payments/3d-secure#three-ds-cards
  # and https://stripe.com/docs/mobile/android/authentication#testing
  ['4000000000003220', '4000000000003063', '4000000000003238', '4000000000003246', '4000000000003253', '4242424242424242'].each { |cc_number|
    payment_method = Stripe::PaymentMethod.create({
      type: 'card',
      card: {
        number: cc_number,
        exp_month: 8,
        exp_year: 2025,
        cvc: '123',
      },
    })

    Stripe::PaymentMethod.attach(
      payment_method.id,
      {
        customer: @customer.id,
      }
    )
  }
end

# This endpoint responds to webhooks sent by Stripe. To use it, you'll need
# to add its URL (https://{your-app-name}.herokuapp.com/stripe-webhook)
# in the webhook settings section of the Dashboard.
# https://dashboard.stripe.com/account/webhooks
# See https://stripe.com/docs/webhooks
post '/stripe-webhook' do
  # Retrieving the event from Stripe guarantees its authenticity
  payload = request.body.read
  event = nil

  begin
      event = Stripe::Event.construct_from(
          JSON.parse(payload, symbolize_names: true)
      )
  rescue JSON::ParserError => e
      # Invalid payload
      status 400
      return
  end

  # Handle the event
  case event.type
  when 'source.chargeable'
    # For sources that require additional user action from your customer
    # (e.g. authorizing the payment with their bank), you should use webhooks
    # to capture a PaymentIntent after the source becomes chargeable.
    # For more information, see https://stripe.com/docs/sources#best-practices
    source = event.data.object # contains a Stripe::Source
    WEBHOOK_CHARGE_CREATION_TYPES = ['bancontact', 'giropay', 'ideal', 'sofort', 'three_d_secure', 'wechat']
    if WEBHOOK_CHARGE_CREATION_TYPES.include?(source.type)
      begin
        payment_intent = Stripe::PaymentIntent.create(
          :amount => source.amount,
          :currency => source.currency,
          :source => source.id,
          :payment_method_types => [source.type],
          :description => "PaymentIntent for Source webhook",
          :confirm => true,
          :capture_method => ENV['CAPTURE_METHOD'] == "manual" ? "manual" : "automatic",
        )
      rescue Stripe::StripeError => e
        status 400
        return log_info("Webhook: Error creating PaymentIntent: #{e.message}")
      end 
      return log_info("Webhook: Created PaymentIntent for source: #{payment_intent.id}")
    end
  when 'payment_intent.succeeded'
    payment_intent = event.data.object # contains a Stripe::PaymentIntent
    log_info("Webhook: PaymentIntent succeeded #{payment_intent.id}")
    
    
    
    # Fulfill the customer's purchase, send an email, etc.
    # When creating the PaymentIntent, consider storing any order
    # information (e.g. order number) as metadata so that you can retrieve it
    # here and use it to complete your customer's purchase.
  when 'payment_intent.amount_capturable_updated'
    # Capture the payment, then fulfill the customer's purchase like above.
    payment_intent = event.data.object # contains a Stripe::PaymentIntent
    log_info("Webhook: PaymentIntent succeeded #{payment_intent.id}")
  else
    # Unexpected event type
    status 400
    return
  end
  status 200
end

# ==== SetupIntent 
# See https://stripe.com/docs/payments/cards/saving-cards-without-payment

# This endpoint is used by the mobile example apps to create a SetupIntent.
# https://stripe.com/docs/api/setup_intents/create
# A real implementation would include controls to prevent misuse
post '/create_setup_intent' do
  payload = params
  if request.content_type != nil and request.content_type.include? 'application/json' and params.empty?
      payload = Sinatra::IndifferentHash[JSON.parse(request.body.read)]
  end
  begin
    setup_intent = Stripe::SetupIntent.create({
      payment_method: payload[:payment_method],
      return_url: payload[:return_url],
      confirm: payload[:payment_method] != nil,
      customer: payload[:customer_id],
      use_stripe_sdk: payload[:payment_method] != nil ? true : nil,
      payment_method_types: payment_methods_for_country(payload[:country]),
    })
  rescue Stripe::StripeError => e
    status 402
    return log_info("Error creating SetupIntent: #{e.message}")
  end

  log_info("SetupIntent successfully created: #{setup_intent.id}")
  status 200
  return {
    :intent => setup_intent.id,
    :secret => setup_intent.client_secret,
    :status => setup_intent.status
  }.to_json
end


post '/check_promo' do
  payload = params
  
    if request.content_type != nil and request.content_type.include? 'application/json' and params.empty?
      payload = Sinatra::IndifferentHash[JSON.parse(request.body.read)]
  end
  
  begin
  promotion_codes = Stripe::PromotionCode.list({code: payload[:code],})

  rescue Stripe::StripeError => e
    status 402
    return log_info("Error checking Promo Code: #{e.message}")
  end

  log_info("Promo code validation completed")
  status 200
  promotion_codes.to_json

end



# ==== PaymentIntent Automatic Confirmation
# See https://stripe.com/docs/payments/payment-intents/ios

# This endpoint is used by the mobile example apps to create a PaymentIntent
# https://stripe.com/docs/api/payment_intents/create
# A real implementation would include controls to prevent misuse
post '/create_payment_intent' do
  payload = params

  if request.content_type != nil and request.content_type.include? 'application/json' and params.empty?
      payload = Sinatra::IndifferentHash[JSON.parse(request.body.read)]
  end

  # Calculate how much to charge the customer
  amount = calculate_price(payload[:products], payload[:shipping], payload[:percent_off])

  begin
    payment_intent = Stripe::PaymentIntent.create(
      :amount => amount,
      :currency => currency_for_country(payload[:country]),
      :customer => payload[:customer_id] || @customer.id,
      :description => "Bloomen App Payment Intent",
      :capture_method => ENV['CAPTURE_METHOD'] == "manual" ? "manual" : "automatic",
      payment_method_types: payment_methods_for_country(payload[:country]),
      
      # Sends receipt
      receipt_email: payload[:email_address],
      
      :metadata => {
      }.merge(payload[:metadata] || {}),
    )
  rescue Stripe::StripeError => e
    status 402
    return log_info("Error creating PaymentIntent: #{e.message}")
  end

  log_info("PaymentIntent successfully created: #{payment_intent.id}")
  status 200
  return {
    :intent => payment_intent.id,
    :secret => payment_intent.client_secret,
    :status => payment_intent.status
  }.to_json
end

# ===== PaymentIntent Manual Confirmation 
# See https://stripe.com/docs/payments/payment-intents/ios-manual

# This endpoint is used by the mobile example apps to create and confirm a PaymentIntent 
# using manual confirmation. 
# https://stripe.com/docs/api/payment_intents/create
# https://stripe.com/docs/api/payment_intents/confirm
# A real implementation would include controls to prevent misuse
post '/confirm_payment_intent' do
  payload = params
  if request.content_type.include? 'application/json' and params.empty?
    payload = Sinatra::IndifferentHash[JSON.parse(request.body.read)]
  end

  begin
    if payload[:payment_intent_id]
      # Confirm the PaymentIntent
      payment_intent = Stripe::PaymentIntent.confirm(payload[:payment_intent_id], {:use_stripe_sdk => true})
    elsif payload[:payment_method_id]
      # Calculate how much to charge the customer
      amount = calculate_price(payload[:products], payload[:shipping], payload[:percent_off])

      # Create and confirm the PaymentIntent
      payment_intent = Stripe::PaymentIntent.create(
        :amount => amount,
        :currency => currency_for_country(payload[:country]),
        :customer => payload[:customer_id] || @customer.id,
        :source => payload[:source],
        :payment_method => payload[:payment_method_id],
        :payment_method_types => payment_methods_for_country(payload[:country]),
        :description => "Bloomen Bouquets",
        :shipping => payload[:shipping],
        :return_url => payload[:return_url],
        :confirm => true,
        :confirmation_method => "manual",
        # Set use_stripe_sdk for mobile apps using Stripe iOS SDK v16.0.0+ or Stripe Android SDK v10.0.0+ 
        # Do not set this on apps using Stripe SDK versions below this.
        :use_stripe_sdk => true, 
        :capture_method => ENV['CAPTURE_METHOD'] == "manual" ? "manual" : "automatic",
        :metadata => {
          :order_id => payload[:payment_intent_id],
        }.merge(payload[:metadata] || {}),
      )
    else
      status 400
      return log_info("Error: Missing params. Pass payment_intent_id to confirm or payment_method to create")
    end 
  rescue Stripe::StripeError => e
    status 402
    return log_info("Error: #{e.message}")
  end

  return generate_payment_response(payment_intent)
end

def generate_payment_response(payment_intent)
  # Note that if your API version is before 2019-02-11, 'requires_action'
  # appears as 'requires_source_action'.
  if payment_intent.status == 'requires_action'
    # Tell the client to handle the action
    status 200
    return {
      requires_action: true,
      secret: payment_intent.client_secret
    }.to_json
  elsif payment_intent.status == 'succeeded' or 
    (payment_intent.status == 'requires_capture' and ENV['CAPTURE_METHOD'] == "manual")
    # The payment didn’t need any additional actions and is completed!
    # Handle post-payment fulfillment
    status 200
    return {
      :success => true
    }.to_json
  else
    # Invalid status
    status 500
    return "Invalid PaymentIntent status"
  end
end

# ===== Custom Methods
# Create new customer at login

post '/create_new_customer' do
  payload = params
  if request.content_type != nil and request.content_type.include? 'application/json' and params.empty?
      payload = Sinatra::IndifferentHash[JSON.parse(request.body.read)]
  end
  begin
      @customer = Stripe::Customer.create({
      description: payload[:fbuid],
      email: payload[:email],
    })
    
    session[:customer_id] = @customer.id

        if (Stripe.api_key.start_with?('sk_test_'))
          # only attach test cards in testmode
          attach_customer_test_cards()
        end
    
  rescue Stripe::StripeError => e
    status 402
    return log_info("Error creating SetupIntent: #{e.message}")
  end
  
  
  content_type :json
  status 200
  @customer.to_json
end

post '/authenticate_stripe_user' do
  
  payload = params
  if request.content_type != nil and request.content_type.include? 'application/json' and params.empty?
      payload = Sinatra::IndifferentHash[JSON.parse(request.body.read)]
  end
  
  if session.has_key?(:customer_id)
    customer_id = session[:customer_id]
    begin
      @customer = Stripe::Customer.retrieve(customer_id)
    rescue Stripe::InvalidRequestError
    end
  else
    @customer = Stripe::Customer.retrieve(payload[:stripeID])
    session[:customer_id] = @customer.id
  end
  
  content_type :json
  status 200
  @customer.to_json
  
end

# ===== Helpers

# This is flower store product hash; this hash lets us calculate the total amount to charge.
EMOJI_STORE = {
  "Standard" => 40000,
  "Romeo" => 70000,
  "Romeo XL" => 100000,
  "Cotton and spray rose bouquet" => 74000,
  "Red rose and eustoma bouquet" => 74000,
  "Cream rose and spray rose bouquet" => 95000,
  "Pink rose bouquet" => 87500,
  "Purple rose and clematis bouquet" => 105000,
  "Garden rose and ornithogalum bouquet" => 99000,
  "Pink rose and clematis bouquet" => 116000
}

def price_lookup(product)
  price = EMOJI_STORE[product]
  raise "Can't find price for %s (%s)" % [product, product.ord.to_s(16)] if price.nil?
  return price
end

def calculate_price(products, shipping, percent_off)
  amount = 0  # Default amount.

  if products
    amount = products.reduce(0) { | sum, product | sum + price_lookup(product) }
  end

  if shipping
    case shipping
    when "fedex"
      amount = amount + 599
    when "fedex_world"
      amount = amount + 2099
    when "ups_worldwide"
      amount = amount + 1099
    when "free"
      amount = amount + 0
    end
  end

  if percent_off
    amount = amount - amount * percent_off / 100
  end

  return amount
end

def currency_for_country(country)
  # Determine currency to use. Generally a store would charge different prices for
  # different countries, but for the sake of simplicity we'll charge X of the local currency.

  case country
  when 'us'
    'hkd'
  when 'mx'
    'hkd'
  when 'my'
    'hkd'
  when 'at', 'be', 'de', 'es', 'it', 'nl', 'pl'
    'hkd'
  when 'au'
    'hkd'
  when 'gb'
    'hkd'
    when 'hk'
      'hkd'
  else
    'hkd'
  end
end

def payment_methods_for_country(country)
  case country
  when 'us'
    %w[card]
  when 'mx'
    %w[card oxxo]
  when 'my'
    %w[card fpx]
  when 'nl'
    %w[card ideal sepa_debit sofort]
  when 'au'
    %w[card au_becs_debit]
  when 'gb'
    %w[card bacs_debit]
  when 'es', 'it'
    %w[card sofort]
  when 'pl'
    %w[card p24]
  when 'be'
    %w[card sofort bancontact]
  when 'de'
    %w[card sofort giropay]
  when 'at'
    %w[card sofort eps]
  when 'sg'
    %w[card alipay]
  else
    %w[card]
  end
end
