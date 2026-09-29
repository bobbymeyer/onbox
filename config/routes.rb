Rails.application.routes.draw do
  # Dispenser mode: the one card in front of Bobby.
  root "dispenser#show"

  # Every source enters here, authenticated by its token.
  post "intake" => "intake#create", as: :intake

  resources :cards, only: [ :edit, :update, :destroy ] do
    member do
      post :stamp
      post :reply
      post :top
      post :later
      post :flip
      post :release
      post :bottom
      post :move
      get :breakdown
      post :decompose
      post :cast
    end
  end

  # Maintenance mode: the whole stack, and the machine behind it.
  get "stack" => "maintenance#show", as: :maintenance
  post "stack/bulk" => "maintenance#bulk", as: :bulk_cards
  post "stack/secretary" => "maintenance#converse", as: :secretary_conversation
  resources :directives, only: [ :create, :destroy ]
  get "secretary" => "secretary#show", as: :secretary
  post "secretary/test" => "secretary#test", as: :test_secretary
  post "secretary/claude" => "secretary#connect_claude", as: :connect_claude
  post "secretary/claude/code" => "secretary#claude_code", as: :claude_code
  post "secretary/claude/cancel" => "secretary#cancel_claude", as: :cancel_claude
  delete "secretary/claude" => "secretary#disconnect_claude", as: :disconnect_claude
  resources :digests, only: :index do
    post :catch_up, on: :collection
  end
  resources :stamps, except: :show
  resources :sources, only: [ :index, :create, :update, :destroy ] do
    member do
      post :poll
      get :connect
      post :authorize
    end
    post :google_client, on: :collection
  end

  get "up" => "rails/health#show", as: :rails_health_check
end
