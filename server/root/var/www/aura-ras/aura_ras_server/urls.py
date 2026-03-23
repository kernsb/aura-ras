from django.contrib import admin
from django.urls import path, include
from api import views

urlpatterns = [
    path('admin/', admin.site.urls),
    path('api/', include('api.urls')),
    
    # Authentication Routing
    path('oidc/', include('mozilla_django_oidc.urls')),
    
    # Dashboard & Web Pages
    path('dashboard/', views.dashboard, name='dashboard'),
    path('settings/', views.server_settings, name='server_settings'),
    path('assignments/', views.computer_assignments, name='computer_assignments'),
    path('', views.dashboard),
]
