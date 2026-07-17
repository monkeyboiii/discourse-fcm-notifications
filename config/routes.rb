DiscourseFcmNotifications::Engine.routes.draw do
  # GET kept for pre-POST app builds; remove after fleet adoption (fix plan Wave 3).
  get '/automatic_subscribe' => 'push#automatic_subscribe'
  post '/automatic_subscribe' => 'push#automatic_subscribe'
  post '/subscribe' => 'push#subscribe'
  post '/unsubscribe' => 'push#unsubscribe'
end

Discourse::Application.routes.draw do
  mount ::DiscourseFcmNotifications::Engine, at: '/fcm_notifications'
end