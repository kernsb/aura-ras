from django.contrib import admin
from django.urls import path, include
from api import views

urlpatterns = [
    path('admin/', admin.site.urls),
    path('api/', include('api.urls')),
    
    # The frontend dashboard routes
    path('dashboard/', views.dashboard, name='dashboard'),
    path('', views.dashboard), # Catch the root URL and serve the dashboard there too!
]
