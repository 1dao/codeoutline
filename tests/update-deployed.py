"""Opt-in signed npm update smoke test. Creates and disables an isolated XUpgate project."""
import argparse,os,json,ssl,urllib.request,subprocess,sys,secrets,shutil,hashlib
from pathlib import Path
parser=argparse.ArgumentParser()
parser.add_argument('--credential-file',required=True,type=Path)
parser.add_argument('--stage',required=True,type=Path)
parser.add_argument('--url',default='https://43.133.255.193:51215')
args=parser.parse_args()
root=Path(__file__).resolve().parents[1]; out=root/'.update-test'/('e2e-'+secrets.token_hex(4));out.mkdir(parents=True)
project='codeoutline-test-'+secrets.token_hex(4)
secret=args.credential_file.read_text().strip().split('=',1)[1]
opener=urllib.request.build_opener(urllib.request.ProxyHandler({}),urllib.request.HTTPSHandler(context=ssl.create_default_context(cafile=str(root/'keys/update-ca.crt'))))
def req(path,body):
 with opener.open(urllib.request.Request(args.url.rstrip('/')+path,data=json.dumps(body).encode(),headers={'Authorization':'Bearer '+secret,'Content-Type':'application/json'}),timeout=60) as r:return r.status

def run(*args,env=None):
 p=subprocess.run(args,capture_output=True,text=True,encoding='utf8',errors='replace',env=env,timeout=150)
 assert p.returncode==0,p.stdout+p.stderr
 return p.stdout.strip()
run('openssl','genpkey','-algorithm','RSA','-pkeyopt','rsa_keygen_bits:2048','-out',str(out/'private.pem'))
run('openssl','pkey','-in',str(out/'private.pem'),'-pubout','-out',str(out/'public.pem'))
assert req('/api/admin/projects',{'id':project,'name':'CodeOutline integration test','publicKey':(out/'public.pem').read_text()})==201
base=args.stage.resolve()/'native'; installed=out/'npm/node_modules';shutil.copytree(base,installed/'@codua/codeoutline-win32-x64');shutil.copytree(args.stage.resolve()/'npm',installed/'codeoutline')
launcher=installed/'codeoutline/launcher/codeoutline.cjs'; env={**os.environ,'CODEOUTLINE_UPDATE_PROJECT':project,'CODEOUTLINE_UPDATE_PUBLIC_KEY':str(out/'public.pem'),'CODEOUTLINE_UPDATE_DIR':str(out/'updates'),'CODEOUTLINE_UPDATE_URL':args.url,'CODEOUTLINE_AUTO_UPDATE':'0'}
def cli(*args):return run('node',str(launcher),*args,env=env)
try:
 assert cli('--version')=='0.1.3'
 for version,seq in [('0.1.4',4),('0.1.5',5)]:
  source=out/version;shutil.copytree(base,source)
  (source/'scripts/codeoutline/version.lua').write_text("return '"+version+"'\n")
  info=json.loads((source/'build-info.json').read_text());info.update(version=version,updateSequence=seq);info['sha256']['scripts/codeoutline/version.lua']=hashlib.sha256((source/'scripts/codeoutline/version.lua').read_bytes()).hexdigest();(source/'build-info.json').write_text(json.dumps(info))
  artifact=out/(version+'.json')
  run(sys.executable,str(root.parent/'xupgate/tools/release.py'),'--project',project,'--version',version,'--sequence',str(seq),'--platform','win32-x64','--entry','scripts/codeoutline/command.lua','--runtime','bin/xnet.exe','--directory',str(source),'--key',str(out/'private.pem'),'--output',str(artifact))
  assert req('/api/admin/projects/'+project+'/releases',json.loads(artifact.read_text()))==201
  assert req('/api/admin/projects/'+project+'/publish',{'version':version,'channel':'stable'})==200
  assert json.loads(cli('update','--check'))['ok']
  if seq==4:assert json.loads(cli('update'))['ok']
  else:
   env['CODEOUTLINE_AUTO_UPDATE']='1'
   assert cli('--version')==version
   env['CODEOUTLINE_AUTO_UPDATE']='0'
  assert cli('--version')==version
  print('npm launcher verified signed update',version,flush=True)
 assert json.loads(cli('update','--rollback'))['ok'];assert cli('--version')=='0.1.4'
 assert json.loads(cli('update','--rollback'))['ok'];assert cli('--version')=='0.1.5'
 env['CODEOUTLINE_UPDATE_DIR']=str(out/'first-update')
 assert json.loads(cli('update'))['ok'];assert cli('--version')=='0.1.5'
 assert json.loads(cli('update','--rollback'))['ok'];assert cli('--version')=='0.1.3'
 env['CODEOUTLINE_UPDATE_DIR']=str(out/'updates')
 # Damaged installed code is rejected before execution.
 for f in (out/'updates').rglob('scripts/codeoutline/version.lua'):f.write_text("error('tampered')\n")
 assert cli('--version')=='0.1.3'
 print('Rollback and corrupt-install fallback verified',flush=True)
finally:
 assert req('/api/admin/projects/'+project+'/enabled',{'enabled':False})==200
 print('Isolated test project disabled',flush=True)
