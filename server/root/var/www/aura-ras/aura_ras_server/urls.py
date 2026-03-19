from django.contrib import admin
from django.urls import path, include
from api import views

urlpatterns = [
    path('admin/', admin.site.urls),
    path('api/', include('api.urls')),
    
    # Add this line for the Entra ID authentication routing
    path('oidc/', include('mozilla_django_oidc.urls')),
    
    path('dashboard/', views.dashboard, name='dashboard'),
    path('settings/', views.server_settings, name='server_settings'),
    path('', views.dashboard),
]
