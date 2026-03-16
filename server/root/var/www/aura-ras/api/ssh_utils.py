import os
import logging
from .models import Computer

logger = logging.getLogger(__name__)

def sync_authorized_keys():
    keys = Computer.objects.values_list('public_key', flat=True)
    keys_content = "\n".join(keys)
    
    auth_keys_path = '/home/aura-tunnel/.ssh/authorized_keys'
    
    try:
        with open(auth_keys_path, 'w') as f:
            f.write("# --- MANAGED BY AURARAS (DO NOT EDIT MANUALLY) ---\n")
            f.write(keys_content)
            f.write("\n")
        logger.info("Successfully synced authorized_keys file.")
    except Exception as e:
        logger.error(f"Failed to write to {auth_keys_path}: {str(e)}")
