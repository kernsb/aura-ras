from django.contrib import admin
from django.utils.html import format_html
from .models import Computer, ConnectionLog

@admin.register(Computer)
class ComputerAdmin(admin.ModelAdmin):
    list_display = ('hostname', 'jssid', 'role', 'terminal_action', 'screenshare_action', 'last_checkin')
    search_fields = ('hostname', 'jssid')
    list_filter = ('role',)
    readonly_fields = ('ssh_port', 'vnc_port', 'last_checkin', 'created_at')

    def terminal_action(self, obj):
        url = f"auraras://connect?type=ssh&port={obj.ssh_port}&host={obj.hostname}"
        return format_html(
            '<a class="button" style="background-color: #417690; color: white; padding: 5px 10px; border-radius: 4px; font-weight: bold;" href="{}">Terminal</a>', 
            url
        )
    terminal_action.short_description = "SSH Access"

    def screenshare_action(self, obj):
        url = f"auraras://connect?type=vnc&port={obj.vnc_port}&host={obj.hostname}"
        return format_html(
            '<a class="button" style="background-color: #79aec8; color: white; padding: 5px 10px; border-radius: 4px; font-weight: bold;" href="{}">Screen Share</a>', 
            url
        )
    screenshare_action.short_description = "VNC Access"

# --- NEW: Makes the connection logs visible in the Admin UI ---
@admin.register(ConnectionLog)
class ConnectionLogAdmin(admin.ModelAdmin):
    list_display = ('start_time', 'admin_user', 'computer', 'session_type', 'is_active', 'duration')
    list_filter = ('is_active', 'session_type', 'admin_user')
    search_fields = ('admin_user', 'computer__hostname')
    readonly_fields = ('start_time', 'end_time', 'computer', 'admin_user', 'session_type', 'is_active')

    def duration(self, obj):
        if obj.end_time:
            dur = obj.end_time - obj.start_time
            return str(dur).split('.')[0]
        return "In Progress"
    duration.short_description = "Duration"