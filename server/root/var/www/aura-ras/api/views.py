import json
import socket
import subprocess
from datetime import timedelta
from django.shortcuts import render, redirect
from django.http import JsonResponse
from django.utils import timezone
from django.views.decorators.csrf import csrf_exempt
from django.views.decorators.http import require_POST
from django.contrib.auth.models import User
from .models import Computer, GlobalSettings
from .ssh_utils import sync_authorized_keys
from .jamf_api import JamfAPI

@csrf_exempt
@require_POST
def register_agent(request):
    try:
        data = json.loads(request.body)
        
        jssid = data.get('jssid')
        role = data.get('role')
        public_key = data.get('public_key')
        hostname = data.get('hostname')

        if not all([jssid, role, public_key, hostname]):
            return JsonResponse({'error': 'Missing required fields in payload'}, status=400)

        computer, created = Computer.objects.update_or_create(
            jssid=jssid,
            defaults={
                'role': role,
                'public_key': public_key,
                'hostname': hostname
            }
        )
        sync_authorized_keys()

        return JsonResponse({
            'status': 'success', 
            'message': 'Registered successfully with AuraRAS',
            'id': computer.id,
            'ssh_port': computer.ssh_port,
            'vnc_port': computer.vnc_port
        }, status=200)

    except json.JSONDecodeError:
        return JsonResponse({'error': 'Invalid JSON format'}, status=400)
    except Exception as e:
        return JsonResponse({'error': str(e)}, status=500)

@csrf_exempt
@require_POST
def unregister_agent(request):
    try:
        data = json.loads(request.body)
        jssid = data.get('jssid')

        if not jssid:
            return JsonResponse({'error': 'Missing jssid in payload'}, status=400)

        deleted_count, _ = Computer.objects.filter(jssid=jssid).delete()
        
        if deleted_count > 0:
            sync_authorized_keys()
            return JsonResponse({'status': 'success', 'message': 'Unregistered successfully'}, status=200)
        else:
            return JsonResponse({'status': 'not_found', 'message': 'Endpoint not found'}, status=404)

    except json.JSONDecodeError:
        return JsonResponse({'error': 'Invalid JSON format'}, status=400)
    except Exception as e:
        return JsonResponse({'error': str(e)}, status=500)

@csrf_exempt
@require_POST
def checkin_agent(request):
    try:
        data = json.loads(request.body)
        jssid = data.get('jssid')

        if not jssid:
            return JsonResponse({'error': 'Missing jssid in payload'}, status=400)

        computer = Computer.objects.filter(jssid=jssid).first()
        if not computer:
            return JsonResponse({'error': 'Computer not found. Please register first.'}, status=404)

        if 'hostname' in data: computer.hostname = data['hostname']
        if 'serial_number' in data: computer.serial_number = data['serial_number']
        if 'last_user' in data: computer.last_user = data['last_user']
        if 'primary_user' in data: computer.primary_user = data['primary_user']
        
        computer.last_checkin = timezone.now()
        computer.save()

        settings = GlobalSettings.load()
        return JsonResponse({
            'status': 'success', 
            'checkin_interval_minutes': settings.agent_checkin_interval_minutes
        }, status=200)

    except json.JSONDecodeError:
        return JsonResponse({'error': 'Invalid JSON format'}, status=400)
    except Exception as e:
        return JsonResponse({'error': str(e)}, status=500)

def dashboard(request):
    settings = GlobalSettings.load()
    
    if request.user.is_authenticated:
        profile = getattr(request.user, 'profile', None)
        role = profile.role if profile else 'Customer'
        theme = profile.theme if profile else 'auto'

        laps_enabled = settings.jamf_laps_enabled if role in ['Server Administrator', 'Desktop Administrator'] else False

        if role in ['Server Administrator', 'Desktop Administrator']:
            computers = Computer.objects.all().order_by('-last_checkin')
        else:
            computers = Computer.objects.filter(assigned_users=request.user).order_by('-last_checkin')
            
        # OPTIMIZATION: Fetch the local port statistics exactly once per page load to save resources
        active_connections = ""
        try:
            # 'ss -tna' gets all active TCP sockets quickly without resolving DNS names
            active_connections = subprocess.check_output(['ss', '-tna']).decode('utf-8')
        except Exception:
            pass

        now = timezone.now()
        
        for comp in computers:
            is_listening = False
            
            # 1. PING THE LOCAL REVERSE TUNNEL PORT
            try:
                with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
                    s.settimeout(0.05) # 50 millisecond timeout is plenty for localhost
                    s.connect(('127.0.0.1', comp.ssh_port))
                    is_listening = True
            except (socket.timeout, ConnectionRefusedError, OSError):
                pass
            
            # 2. EVALUATE STATUS
            if is_listening:
                is_active = False
                ssh_target = f"127.0.0.1:{comp.ssh_port}"
                vnc_target = f"127.0.0.1:{comp.vnc_port}"
                
                # Check line-by-line to ensure ESTAB and the port are on the same active connection line
                for line in active_connections.splitlines():
                    if line.startswith("ESTAB") and (ssh_target in line or vnc_target in line):
                        is_active = True
                        break
                        
                if is_active:
                    comp.status_color = 'blue'
                    comp.status_text = 'Active Session Established'
                else:
                    comp.status_color = 'green'
                    comp.status_text = 'Online & Tunnel Ready'
            else:
                if comp.last_checkin and (now - comp.last_checkin) <= timedelta(hours=24):
                    comp.status_color = 'yellow'
                    comp.status_text = 'Offline (Seen in the last 24 hours)'
                else:
                    comp.status_color = 'red'
                    comp.status_text = 'Offline (Unreachable for > 24 hours)'

    else:
        computers = []
        role = None
        theme = 'auto'
        laps_enabled = False

    return render(request, 'api/dashboard.html', {
        'computers': computers,
        'user_role': role,
        'user_theme': theme,
        'laps_enabled': laps_enabled
    })

def computer_assignments(request):
    if not request.user.is_authenticated:
        return redirect('oidc_authentication_init')
        
    profile = getattr(request.user, 'profile', None)
    role = profile.role if profile else 'Customer'
    
    if role not in ['Server Administrator', 'Desktop Administrator']:
        return redirect('dashboard')
        
    customer_users = User.objects.filter(profile__role='Customer').order_by('username')
    computers = Computer.objects.all().order_by('hostname')
    
    if request.method == 'POST':
        comp_id = request.POST.get('computer_id')
        selected_user_ids = request.POST.getlist('assigned_users')
        
        if comp_id:
            comp = Computer.objects.filter(id=comp_id).first()
            if comp:
                comp.assigned_users.set(selected_user_ids)
        
        return redirect('computer_assignments')
        
    return render(request, 'api/assignments.html', {
        'computers': computers,
        'customers': customer_users,
        'user_role': role,
        'user_theme': profile.theme if profile else 'auto'
    })

def server_settings(request):
    if not request.user.is_authenticated:
        return redirect('oidc_authentication_init')
        
    profile = getattr(request.user, 'profile', None)
    role = profile.role if profile else 'Customer'
    
    if role not in ['Server Administrator', 'Desktop Administrator', 'Customer']:
        return redirect('dashboard')
        
    settings = GlobalSettings.load()
    success = False
    
    if request.method == 'POST':
        if profile:
            theme = request.POST.get('theme')
            if theme in ['auto', 'light', 'dark']:
                profile.theme = theme
            timezone = request.POST.get('timezone')
            if timezone:
                profile.timezone = timezone
            profile.save()

        if role == 'Server Administrator':
            settings.jamf_url = request.POST.get('jamf_url')
            settings.jamf_client_id = request.POST.get('jamf_client_id')
            
            new_secret = request.POST.get('jamf_client_secret')
            if new_secret:
                settings.jamf_client_secret = new_secret
                
            settings.jamf_laps_enabled = request.POST.get('jamf_laps_enabled') == 'on'
            settings.prestage_laps_type = request.POST.get('prestage_laps_type', 'jamf')
            settings.macoslaps_ea_id = request.POST.get('macoslaps_ea_id', '')
            
            interval = request.POST.get('agent_checkin_interval_minutes')
            if interval and interval.isdigit():
                settings.agent_checkin_interval_minutes = int(interval)
                
            # Parse and save the custom server port configuration
            settings.custom_server_port_enabled = request.POST.get('custom_server_port_enabled') == 'on'
            if settings.custom_server_port_enabled:
                port = request.POST.get('custom_server_port')
                if port and port.isdigit():
                    settings.custom_server_port = int(port)
            else:
                settings.custom_server_port = 9922
                
            settings.save()
            
        success = True
        
    return render(request, 'api/settings.html', {
        'settings': settings, 
        'user_role': role,
        'profile': profile,
        'user_theme': profile.theme if profile else 'auto',
        'success': success
    })

def laps_usernames(request, jssid):
    if not request.user.is_authenticated or not hasattr(request.user, 'profile'):
        return JsonResponse({'status': 'error', 'message': 'Unauthorized'}, status=403)
        
    if request.user.profile.role not in ['Server Administrator', 'Desktop Administrator']:
        return JsonResponse({'status': 'error', 'message': 'Access Denied'}, status=403)
        
    try:
        settings = GlobalSettings.load()
        api = JamfAPI(settings.jamf_url, settings.jamf_client_id, settings.jamf_client_secret)
        mgmt_id = api.get_management_id(jssid)
        
        accounts = api.get_laps_accounts(mgmt_id)
        jamf_user = None
        prestage_user = None
        
        for acc in accounts:
            if acc.get('userSource') == 'JMF':
                jamf_user = acc.get('username')
            elif acc.get('userSource') == 'MDM':
                if settings.prestage_laps_type == 'jamf':
                    prestage_user = acc.get('username')

        if settings.prestage_laps_type == 'macoslaps':
            if settings.macoslaps_ea_id:
                ea_val = api.get_extension_attribute(jssid, settings.macoslaps_ea_id)
                if ea_val:
                    prestage_user = "paeadmin"

        return JsonResponse({
            'status': 'success',
            'jamf_user': jamf_user,
            'prestage_user': prestage_user
        })
    except Exception as e:
        return JsonResponse({'status': 'error', 'message': str(e)}, status=500)

def laps_password(request, jssid, account_type):
    if not request.user.is_authenticated or not hasattr(request.user, 'profile'):
        return JsonResponse({'status': 'error', 'message': 'Unauthorized'}, status=403)
        
    if request.user.profile.role not in ['Server Administrator', 'Desktop Administrator']:
        return JsonResponse({'status': 'error', 'message': 'Access Denied'}, status=403)
        
    settings = GlobalSettings.load()
    if not settings.jamf_laps_enabled:
        return JsonResponse({'status': 'error', 'message': 'LAPS is currently disabled globally.'}, status=400)
        
    try:
        api = JamfAPI(settings.jamf_url, settings.jamf_client_id, settings.jamf_client_secret)
        
        if account_type == 'jamf':
            mgmt_id = api.get_management_id(jssid)
            accounts = api.get_laps_accounts(mgmt_id)
            username = next((acc['username'] for acc in accounts if acc.get('userSource') == 'JMF'), None)
            if not username:
                return JsonResponse({'status': 'error', 'message': 'Jamf Admin LAPS account not found.'}, status=404)
            password = api.get_laps_password(mgmt_id, username)
            return JsonResponse({'status': 'success', 'password': password})
            
        elif account_type == 'prestage':
            if settings.prestage_laps_type == 'macoslaps':
                if not settings.macoslaps_ea_id:
                    return JsonResponse({'status': 'error', 'message': 'macOSLAPS EA ID is not configured.'}, status=400)
                password = api.get_extension_attribute(jssid, settings.macoslaps_ea_id)
                if not password:
                    return JsonResponse({'status': 'error', 'message': 'macOSLAPS password was empty or not found.'}, status=404)
                return JsonResponse({'status': 'success', 'password': password})
            else:
                mgmt_id = api.get_management_id(jssid)
                accounts = api.get_laps_accounts(mgmt_id)
                username = next((acc['username'] for acc in accounts if acc.get('userSource') == 'MDM'), None)
                if not username:
                    return JsonResponse({'status': 'error', 'message': 'PreStage Admin LAPS account not found.'}, status=404)
                password = api.get_laps_password(mgmt_id, username)
                return JsonResponse({'status': 'success', 'password': password})
        else:
            return JsonResponse({'status': 'error', 'message': 'Invalid account type specified.'}, status=400)
            
    except Exception as e:
        return JsonResponse({'status': 'error', 'message': f"Jamf API Error: {str(e)}"}, status=500)
