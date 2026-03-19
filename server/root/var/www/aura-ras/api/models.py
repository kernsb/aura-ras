from django.db import models
from django.contrib.auth.models import User

class GlobalSettings(models.Model):
    # Singleton pattern (only one row should ever exist)
    jamf_url = models.URLField(max_length=255, blank=True, null=True, help_text="e.g., https://purdue.jamfcloud.com")
    jamf_client_id = models.CharField(max_length=255, blank=True, null=True)
    jamf_client_secret = models.CharField(max_length=255, blank=True, null=True)
    jamf_laps_enabled = models.BooleanField(default=False)
    agent_checkin_interval_minutes = models.IntegerField(default=60)
    
    # New PreStage Admin LAPS Fields
    PRESTAGE_LAPS_CHOICES = (
        ('jamf', 'Jamf Built-in LAPS'),
        ('macoslaps', 'macOSLAPS (Extension Attribute)'),
    )
    prestage_laps_type = models.CharField(max_length=20, choices=PRESTAGE_LAPS_CHOICES, default='jamf')
    macoslaps_ea_id = models.CharField(max_length=50, blank=True, null=True)
    
    def save(self, *args, **kwargs):
        self.pk = 1
        super(GlobalSettings, self).save(*args, **kwargs)

    def delete(self, *args, **kwargs):
        pass

    @classmethod
    def load(cls):
        obj, created = cls.objects.get_or_create(pk=1)
        return obj

    def __str__(self):
        return "AuraRAS Global Settings"

class UserProfile(models.Model):
    ROLE_CHOICES = (
        ('Server Administrator', 'Server Administrator'),
        ('Desktop Administrator', 'Desktop Administrator'),
        ('Customer', 'Customer'),
        ('Unassigned', 'Unassigned'),
    )
    THEME_CHOICES = (
        ('auto', 'System Default'),
        ('light', 'Light Mode'),
        ('dark', 'Dark Mode'),
    )
    user = models.OneToOneField(User, on_delete=models.CASCADE, related_name='profile')
    role = models.CharField(max_length=50, choices=ROLE_CHOICES, default='Customer')
    
    # New Personal Preferences
    theme = models.CharField(max_length=10, choices=THEME_CHOICES, default='auto')
    timezone = models.CharField(max_length=50, default='America/New_York')

    def __str__(self):
        return f"{self.user.username} - {self.role}"

class Computer(models.Model):
    ROLE_CHOICES = (
        ('Administrator', 'Administrator'),
        ('Endpoint', 'Endpoint'),
    )
    
    # Django automatically adds an auto-incrementing 'id' field
    jssid = models.IntegerField(unique=True)
    hostname = models.CharField(max_length=255)
    role = models.CharField(max_length=50, choices=ROLE_CHOICES, default='Endpoint')
    public_key = models.TextField()
    
    # We allow null temporarily so they can be generated after the initial ID is saved
    ssh_port = models.IntegerField(editable=False, null=True)
    vnc_port = models.IntegerField(editable=False, null=True)
    
    last_checkin = models.DateTimeField(auto_now=True)
    created_at = models.DateTimeField(auto_now_add=True)

    # Link specific Entra ID users to this computer for the "Customer" role
    assigned_users = models.ManyToManyField(User, blank=True, related_name='assigned_computers')

    def save(self, *args, **kwargs):
        if not self.id:
            # 1. Save first to generate the auto-incrementing ID
            super(Computer, self).save(*args, **kwargs)
            
            # 2. Calculate the safe ports
            self.ssh_port = self.id + 40000
            self.vnc_port = self.id + 50000
            
            # 3. Remove force_insert so the second save does an UPDATE
            kwargs.pop('force_insert', None)
            super(Computer, self).save(*args, **kwargs)
        else:
            # SELF-HEALING: If the row exists but ports are missing/corrupted
            if not self.ssh_port or not self.vnc_port:
                self.ssh_port = self.id + 40000
                self.vnc_port = self.id + 50000
            
            # Standard save for an existing object
            super(Computer, self).save(*args, **kwargs)

    def __str__(self):
        return f"{self.hostname} (AuraID: {self.id})"
