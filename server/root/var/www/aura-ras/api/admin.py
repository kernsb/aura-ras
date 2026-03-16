from django.contrib import admin
from .models import Computer

@admin.register(Computer)
class ComputerAdmin(admin.ModelAdmin):
    list_display = ('hostname', 'jssid', 'role', 'ssh_port', 'vnc_port', 'last_checkin')
    search_fields = ('hostname', 'jssid')
    list_filter = ('role',)
    readonly_fields = ('ssh_port', 'vnc_port', 'last_checkin', 'created_at')
