"""Open the Linux audio device muted, verify 128/256-frame setup and release it.

No monitoring is enabled and no audio is saved. Requires the desktop audio server.
Usage: python3 tool/check_linux_audio_latency.py [absolute-host-path]
"""
import json
import pathlib
import select
import subprocess
import sys
import time

host = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else
                    'build/linux/x64/debug/bundle/guitarbook_effects_host').resolve()

def metadata():
    return subprocess.run(['pw-metadata', '-n', 'settings'], check=True,
                          text=True, capture_output=True, timeout=5).stdout

before = metadata()
process = subprocess.Popen([str(host)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL, text=True)
sequence = 0

def send(command, **arguments):
    global sequence
    sequence += 1
    process.stdin.write(json.dumps({'id': sequence, 'command': command, **arguments}) + '\n')
    process.stdin.flush()
    while select.select([process.stdout], [], [], 15)[0]:
        line = process.stdout.readline()
        if not line:
            raise RuntimeError('Host exited unexpectedly')
        try:
            response = json.loads(line)
        except ValueError:
            continue
        if response.get('id') == sequence:
            if 'error' in response:
                raise RuntimeError(response['error'])
            return response['result']
    raise TimeoutError('Host did not respond')

try:
    for frames in (128, 256):
        result = send('audioBuffer', frames=frames)
        assert not result['running'], 'Test must remain muted'
        assert result['bufferSize'] == frames, result
        assert result['sampleRate'] == 48000, result
        time.sleep(0.5)
        result = send('status')
        print(json.dumps({key: result[key] for key in
                         ('backend', 'sampleRate', 'requestedBuffer', 'bufferSize',
                          'blockMs', 'latencyMs', 'pipewireQuantum', 'xruns')}, ensure_ascii=False))
        graph = subprocess.run(['pw-top', '-b', '-n', '2'], text=True,
                               capture_output=True, timeout=6).stdout
        print(graph)
    result = send('stop')
    assert not result['running'] and not result['device']
finally:
    process.stdin.close()
    try:
        process.wait(timeout=4)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()
# Runtime node requests must not mutate global settings metadata.
assert before == metadata(), 'Global PipeWire settings changed'
print('Muted device setup, buffer switching and release passed; global metadata unchanged')
