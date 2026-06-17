from django.db import models
from django.contrib.auth.models import User

class GlobalSettings(models.Model):
    jamf_url = models.URLField(max_length=255, blank=True, null=True)
    jamf_client_id = models.CharField(max_length=255, blank=True, null=True)
    jamf_client_secret = models.CharField(max_length=255, blank=True, null=True)
    jamf_laps_enabled = models.BooleanField(default=False)
    agent_checkin_interval_minutes = models.IntegerField(default=60)
    
    PRESTAGE_LAPS_CHOICES = (
        ('jamf', 'Jamf Built-in LAPS'),
        ('macoslaps', 'macOSLAPS (Extension Attribute)'),
    )
    prestage_laps_type = models.CharField(max_length=20, choices=PRESTAGE_LAPS_CHOICES, default='jamf')
    macoslaps_ea_id = models.CharField(max_length=50, blank=True, null=True)
    
    custom_server_port_enabled = models.BooleanField(default=False)
    custom_server_port = models.IntegerField(default=9922)

    def save(self, *args, **kwargs):
        self.pk = 1
        super(GlobalSettings, self).save(*args, **kwargs)

    @classmethod
    def load(cls):
        obj, created = cls.objects.get_or_create(pk=1)
        return obj

class UserProfile(models.Model):
    user = models.OneToOneField(User, on_delete=models.CASCADE, related_name='profile')
    role = models.CharField(max_length=50, default='Customer')
    theme = models.CharField(max_length=10, default='auto')
    timezone = models.CharField(max_length=50, default='UTC')
    rows_per_page = models.IntegerField(default=25)
    auto_refresh_interval = models.IntegerField(default=15)

class Computer(models.Model):
    ROLE_CHOICES = (
        ('Administrator', 'Administrator'),
        ('Endpoint', 'Endpoint'),
    )
    
    jssid = models.IntegerField(unique=True)
    hostname = models.CharField(max_length=255)
    role = models.CharField(max_length=50, choices=ROLE_CHOICES, default='Endpoint')
    public_key = models.TextField()
    
    ssh_port = models.IntegerField(editable=False, null=True)
    vnc_port = models.IntegerField(editable=False, null=True)
    
    serial_number = models.CharField(max_length=100, blank=True, null=True)
    last_user = models.CharField(max_length=100, blank=True, null=True)
    primary_user = models.CharField(max_length=100, blank=True, null=True)
    assigned_users = models.ManyToManyField(User, blank=True, related_name='assigned_computers')
    
    last_checkin = models.DateTimeField(auto_now=True)
    created_at = models.DateTimeField(auto_now_add=True)
    
    # Track the last logged "dot" state so we don't spam the text log file
    last_logged_status = models.CharField(max_length=100, default='Online & Tunnel Ready')

    def save(self, *args, **kwargs):
        is_new = self.id is None
        super(Computer, self).save(*args, **kwargs)
        
        if is_new or self.ssh_port is None or self.vnc_port is None:
            self.ssh_port = self.id + 40000
            self.vnc_port = self.id + 50000
            super(Computer, self).save(update_fields=['ssh_port', 'vnc_port'])

    def __str__(self):
        return f"{self.hostname} (AuraID: {self.id})"

# --- NEW: Tracks Active Connections for real-time reporting ---
class ConnectionLog(models.Model):
    computer = models.ForeignKey(Computer, on_delete=models.CASCADE)
    admin_user = models.CharField(max_length=150)
    session_type = models.CharField(max_length=50) # 'Screen Share' or 'Terminal'
    start_time = models.DateTimeField(auto_now_add=True)
    end_time = models.DateTimeField(null=True, blank=True)
    is_active = models.BooleanField(default=True)
    
    def __str__(self):
        return f"[{self.start_time.strftime('%Y-%m-%d %H:%M')}] {self.admin_user} -> {self.computer.hostname} ({self.session_type})"