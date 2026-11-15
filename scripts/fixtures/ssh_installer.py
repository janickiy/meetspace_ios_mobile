import paramiko,socket,threading,json,re,time,pathlib,logging,io
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization
logging.disable(logging.CRITICAL)
root=pathlib.Path('/tmp/meetspace-ssh-fixture');root.mkdir(exist_ok=True)
private=Ed25519PrivateKey.generate().private_bytes(serialization.Encoding.PEM,serialization.PrivateFormat.OpenSSH,serialization.NoEncryption())
key=paramiko.Ed25519Key(file_obj=io.StringIO(private.decode()))
counts={'connections':0,'auth':0,'exec':0,'payloads':0}
lock=threading.Lock()
def record(k):
 with lock:
  counts[k]+=1
  temp=root/'counts.tmp';temp.write_text(json.dumps(counts));temp.replace(root/'counts.json')
class Server(paramiko.ServerInterface):
 def check_auth_password(self,user,password):
  record('auth')
  if user=='slowfixture':time.sleep(3)
  return paramiko.AUTH_SUCCESSFUL if user in ('fixture','slowfixture') and password=='fixture-only-password' else paramiko.AUTH_FAILED
 def get_allowed_auths(self,user):return 'password'
 def check_channel_request(self,kind,id):return paramiko.OPEN_SUCCEEDED if kind=='session' else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED
 def check_channel_exec_request(self,channel,command):
  record('exec')
  def answer():
   match=re.search(rb'stdin.buffer.read\((\d+)\)',command)
   if not match:channel.send_exit_status(1);channel.close();return
   size=int(match.group(1));body=b''
   while len(body)<size:
    piece=channel.recv(min(32768,size-len(body)))
    if not piece:return
    body+=piece
   record('payloads')
   channel.send(b'MS_TEST_OK');channel.send_exit_status(0);channel.close()
  threading.Thread(target=answer,daemon=True).start();return True
sock=socket.socket();sock.bind(('127.0.0.1',0));sock.listen(10)
(root/'endpoint.json').write_text(json.dumps({'port':sock.getsockname()[1],'hostKey':key.get_name()+' '+key.get_base64()}))
(root/'counts.json').write_text(json.dumps(counts))
def serve(conn):
 record('connections');transport=paramiko.Transport(conn);transport.add_server_key(key)
 try:
  transport.start_server(server=Server())
  while transport.is_active():time.sleep(.05)
 except Exception:pass
 finally:transport.close()
while True:
 conn,_=sock.accept();threading.Thread(target=serve,args=(conn,),daemon=True).start()
