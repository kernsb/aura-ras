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
    agent_checkin_interval_minutes = models.IntegerField(default=60)
    
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
    
    # Phase 4: Telemetry Fields
    serial_number = models.CharField(max_length=100, blank=True, null=True)
    last_user = models.CharField(max_length=100, blank=True, null=True)
    primary_user = models.CharField(max_length=100, blank=True, null=True)
    
    # Phase 4: Customer Assignments
    assigned_users = models.ManyToManyField(User, blank=True, related_name='assigned_computers')
    
    last_checkin = models.DateTimeField(auto_now=True)
    created_at = models.DateTimeField(auto_now_add=True)

    def save(self, *args, **kwargs):
        # First, save the model natively to generate the auto-incrementing ID if it doesn't exist
        is_new = self.id is None
        super(Computer, self).save(*args, **kwargs)
        
        # Now that it has an ID, calculate the ports and explicitly update ONLY those fields
        if is_new or self.ssh_port is None or self.vnc_port is None:
            self.ssh_port = self.id + 40000
            self.vnc_port = self.id + 50000
            super(Computer, self).save(update_fields=['ssh_port', 'vnc_port'])

    def __str__(self):
        return f"{self.hostname} (AuraID: {self.id})"
