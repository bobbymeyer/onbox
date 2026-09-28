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
    end
  end

  # Maintenance mode: the whole stack, and the machine behind it.
  get "stack" => "maintenance#show", as: :maintenance
  resources :stamps, except: :show
  resources :sources, only: [ :index, :create, :update, :destroy ] do
    post :poll, on: :member
  end

  get "up" => "rails/health#show", as: :rails_health_check
end
