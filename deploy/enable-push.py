"""Validate the two Firebase files and enable notification sending on AWS.

Run from the repository root after downloading the files. Never logs secrets.
"""
import json
import pathlib
import subprocess

root = pathlib.Path(__file__).resolve().parent.parent
android = root / 'android/app/google-services.json'
account = root / 'deploy/.secrets/firebase-service-account.json'
if not android.is_file() or not account.is_file():
    raise SystemExit('Both android/app/google-services.json and deploy/.secrets/firebase-service-account.json are required.')
app = json.loads(android.read_text())
key = json.loads(account.read_text())
assert app['project_info']['project_number'] == '379348658627', 'Use the existing Aida Google project'
assert any(c['client_info'].get('android_client_info', {}).get('package_name') == 'com.yashpatodkar.aida'
           for c in app['client']), 'The Android package does not match Aida'
assert key['type'] == 'service_account' and key.get('private_key'), 'A Firebase service account key is required'
assert key['project_id'] == app['project_info']['project_id'], 'The two Firebase files must belong to the same project'
account.chmod(0o600)
ssh = ['-i', str(root / 'deploy/.secrets/aida-aws'), '-o',
       'UserKnownHostsFile=' + str(root / 'deploy/.secrets/known_hosts')]
host = 'ubuntu@44.209.97.214'
subprocess.run(['scp', *ssh, str(account), host + ':/home/ubuntu/aida-fcm.json'], check=True)
subprocess.run(['scp', *ssh, str(root / 'deploy/compose.aws.yaml'), host + ':/home/ubuntu/aida-compose.yaml'], check=True)
script = '''set -eu
sudo mkdir -p /opt/aida/deploy/.secrets/firebase
sudo chown 1000:1000 /opt/aida/deploy/.secrets/firebase
sudo chmod 700 /opt/aida/deploy/.secrets/firebase
sudo install -o 1000 -g 1000 -m 400 /home/ubuntu/aida-fcm.json /opt/aida/deploy/.secrets/firebase/service-account.json
rm /home/ubuntu/aida-fcm.json
sudo install -m 644 /home/ubuntu/aida-compose.yaml /opt/aida/deploy/compose.aws.yaml
rm /home/ubuntu/aida-compose.yaml
sudo python3 - <<'PY'
from pathlib import Path
p = Path('/opt/aida/deploy/.secrets/server.env')
lines = [s for s in p.read_text().splitlines() if not s.startswith('GOOGLE_APPLICATION_CREDENTIALS=')]
lines.append('GOOGLE_APPLICATION_CREDENTIALS=/run/aida-firebase/service-account.json')
p.write_text('\\n'.join(lines) + '\\n')
p.chmod(0o600)
PY
sudo docker compose -f /opt/aida/deploy/compose.aws.yaml up -d --force-recreate api
sudo docker exec aida-api-1 node --input-type=module -e 'import { GoogleAuth } from "google-auth-library"; const auth=new GoogleAuth({scopes:["https://www.googleapis.com/auth/firebase.messaging"]}); await auth.getAccessToken(); console.log("Firebase service-account authorization succeeded");'
'''
subprocess.run(['ssh', *ssh, host, 'sh -s'], input=script, text=True, check=True)
print('AWS notification sending is configured. Rebuild the APK to include google-services.json.')
