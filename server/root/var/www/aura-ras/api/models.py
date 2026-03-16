from django.db import models

class Computer(models.Model):
    ROLE_CHOICES = (
        ('Administrator', 'Administrator'),
        ('Endpoint', 'Endpoint'),
    )
    
    # jssid is no longer the primary key, Django automatically adds an auto-incrementing 'id' field
    jssid = models.IntegerField(unique=True)
    hostname = models.CharField(max_length=255)
    role = models.CharField(max_length=50, choices=ROLE_CHOICES, default='Endpoint')
    public_key = models.TextField()
    
    ssh_port = models.IntegerField(editable=False, null=True)
    vnc_port = models.IntegerField(editable=False, null=True)
    
    last_checkin = models.DateTimeField(auto_now=True)
    created_at = models.DateTimeField(auto_now_add=True)

    def save(self, *args, **kwargs):
        if not self.id:
            super(Computer, self).save(*args, **kwargs)
        
        self.ssh_port = self.id + 40000
        self.vnc_port = self.id + 50000
        super(Computer, self).save(*args, **kwargs)

    def __str__(self):
        return f"{self.hostname} (AuraID: {self.id})"