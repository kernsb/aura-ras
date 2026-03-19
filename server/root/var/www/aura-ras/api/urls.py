from django.urls import path
from . import views

urlpatterns = [
    # The Swift agent endpoints
    path('register', views.register_agent, name='api_register'),
    path('unregister', views.unregister_agent, name='api_unregister'),
    
    # LAPS API Endpoints
    path('laps/usernames/<int:jssid>', views.laps_usernames, name='laps_usernames'),
    path('laps/password/<int:jssid>/<str:account_type>', views.laps_password, name='laps_password'),
]
