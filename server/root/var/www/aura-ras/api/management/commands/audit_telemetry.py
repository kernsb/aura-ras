import subprocess
import logging
import socket
from datetime import timedelta
from django.core.management.base import BaseCommand
from django.utils import timezone
from api.models import Computer, ConnectionLog, GlobalSettings

# Tap into the text file logger
aura_logger = logging.getLogger('aura_events')

class Command(BaseCommand):
    help = 'Audits active TCP sockets to log disconnects, and audits computer check-in times to log state changes.'

    def handle(self, *args, **options):
        now = timezone.now()
        settings_obj = GlobalSettings.load()
        
        # ---------------------------------------------------------------------
        # PART 1: AUDIT TCP SOCKETS FOR DISCONNECTS
        # ---------------------------------------------------------------------
        try:
            active_connections = subprocess.check_output(['ss', '-tna']).decode('utf-8')
        except Exception as e:
            active_connections = ""
            self.stderr.write(self.style.ERROR(f"Failed to read sockets: {e}"))
            
        open_sessions = ConnectionLog.objects.filter(is_active=True)
        
        for session in open_sessions:
            comp = session.computer
            is_active = False
            
            # Identify which port we are auditing
            port_to_check = comp.ssh_port if session.session_type == 'Terminal' else comp.vnc_port
            suffix = f":{port_to_check}"
            
            # Check the server's raw TCP streams
            for line in active_connections.splitlines():
                if line.startswith("ESTAB"):
                    parts = line.split()
                    if len(parts) >= 5:
                        local_addr = parts[3]
                        peer_addr = parts[4]
                        if local_addr.endswith(suffix):
                            try:
                                peer_port = int(peer_addr.rsplit(':', 1)[-1])
                                # Only consider it active if an external ephemeral port is connected to it
                                if peer_port >= 32768:
                                    is_active = True
                                    break
                            except ValueError:
                                pass
            
            # If the socket is dead, close the record and log the disconnect
            if not is_active:
                session.is_active = False
                session.end_time = now
                session.save()
                
                # Format duration cleanly (e.g., 0:15:30)
                duration = session.end_time - session.start_time
                duration_str = str(duration).split('.')[0] 
                
                aura_logger.info(f"SESSION DISCONNECTED | Admin: {session.admin_user} | Type: {session.session_type} | Target: {comp.hostname} ({comp.serial_number}) | Duration: {duration_str}")


        # ---------------------------------------------------------------------
        # PART 2: AUDIT "DOT" STATE STATUS CHANGES
        # ---------------------------------------------------------------------
        interval_minutes = int(settings_obj.agent_checkin_interval_minutes) if settings_obj.agent_checkin_interval_minutes else 60
        grace_period_seconds = (interval_minutes + 15) * 60
        
        computers = Computer.objects.all()
        for comp in computers:
            seconds_since = abs((now - comp.last_checkin).total_seconds()) if comp.last_checkin else 9999999
            current_status = 'Online & Tunnel Ready' # Baseline assumption
            
            if seconds_since > 86400:
                current_status = 'Offline (Unreachable for > 24 hours)'
            elif seconds_since > grace_period_seconds:
                current_status = 'Offline / Sleeping (Missed recent check-in)'
            else:
                is_listening = False
                try:
                    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
                        s.settimeout(0.05)
                        s.connect(('127.0.0.1', comp.ssh_port))
                        is_listening = True
                except Exception:
                    pass
                    
                if not is_listening:
                    current_status = 'Tunnel Disconnected (Network Interruption)'
                    
            # If the state has changed since our last check, log it to the text file!
            if current_status != comp.last_logged_status:
                aura_logger.info(f"STATUS CHANGE | Target: {comp.hostname} ({comp.serial_number}) | New Status: {current_status}")
                comp.last_logged_status = current_status
                comp.save(update_fields=['last_logged_status'])
                
        self.stdout.write(self.style.SUCCESS('Successfully audited connection telemetry.'))