from django.urls import path
from . import views

urlpatterns = [
    # The Swift agent endpoints
    path('register', views.register_agent, name='api_register'),
    path('unregister', views.unregister_agent, name='api_unregister'),
]
