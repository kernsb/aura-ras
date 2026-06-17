from django.urls import path
from . import views

urlpatterns = [
    path('register', views.register_agent, name='api_register'),
    path('unregister', views.unregister_agent, name='api_unregister'),
    path('checkin', views.checkin_agent, name='api_checkin'),
    
    path('user/preferences/update/', views.update_user_preferences, name='update_user_preferences'),
    path('user/log-session/', views.log_session_event, name='log_session_event'), # NEW LOGGING ENDPOINT
    
    path('laps/usernames/<int:jssid>', views.laps_usernames, name='laps_usernames'),
    path('laps/password/<int:jssid>/<str:account_type>', views.laps_password, name='laps_password'),
]