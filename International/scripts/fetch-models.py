"""Build-time model download. The distributed application makes no network calls."""
import hashlib, json, pathlib, subprocess, sys
destination = pathlib.Path(sys.argv[1]); destination.mkdir(parents=True, exist_ok=True)
for model in json.loads(pathlib.Path(__file__).with_name('models.json').read_text()):
    target = destination / model['name']
    if not target.exists():
        temporary = target.with_suffix('.download')
        subprocess.run(['curl', '--fail', '--location', '--retry', '3', model['url'], '-o', str(temporary)], check=True)
        temporary.replace(target)
    hasher = hashlib.sha256()
    with target.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            hasher.update(chunk)
    digest = hasher.hexdigest()
    if digest != model['sha256']: raise RuntimeError('Checksum mismatch: ' + model['name'])
    print('Verified', model['name'])
