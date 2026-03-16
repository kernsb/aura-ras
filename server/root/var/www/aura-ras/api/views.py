import json
from django.shortcuts import render
from django.http import JsonResponse
from django.views.decorators.csrf import csrf_exempt
from django.views.decorators.http import require_POST
from .models import Computer
from .ssh_utils import sync_authorized_keys

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

def dashboard(request):
    computers = Computer.objects.all().order_by('-last_checkin')
    return render(request, 'api/dashboard.html', {'computers': computers})
