"""Generate small local fixtures; no network or real-device access."""
from pathlib import Path
import subprocess
import sys
from mutagen.mp4 import MP4
from mutagen.id3 import ID3, COMM, USLT, TSOT, TSOP, TSOA

root = Path(sys.argv[1])
for suffix, disc, codec in [('mp3', 1, 'libmp3lame'), ('m4a', 2, 'aac'), ('flac', 3, 'flac'), ('m4a', 4, 'aac')]:
    path = root / 'Folder Artist' / f'Folder Album {disc}' / f'09 - Wrong Title.{suffix}'
    path.parent.mkdir(parents=True, exist_ok=True)
    metadata = dict(title='Tagged Title', artist='Tagged Artist', album='Tagged Album',
                    album_artist='Various Artists', genre='Rock', date='2024-02-01',
                    track='3/12', disc=f'{disc}/3', composer='Test Composer', compilation='1',
                    sort_name='Title Sort', sort_artist='Artist Sort', sort_album='Album Sort',
                    sort_album_artist='Album Artist Sort', sort_composer='Composer Sort',
                    lyrics='Test lyrics',
                    grouping='Test Group', comment='Test Comment', bpm='123')
    args = ['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', 'sine=frequency=440:duration=1', '-c:a', codec]
    for key, value in metadata.items():
        args += ['-metadata', f'{key}={value}']
    subprocess.run(args + [str(path)], check=True)
    if suffix == 'mp3':
        audio = ID3(path)
        audio.add(COMM(encoding=3, lang='eng', desc='', text=['Test Comment']))
        audio.add(USLT(encoding=3, lang='eng', desc='', text='Test lyrics'))
        audio.add(TSOT(encoding=3, text=['Title Sort']))
        audio.add(TSOP(encoding=3, text=['Artist Sort']))
        audio.add(TSOA(encoding=3, text=['Album Sort']))
        audio.save(path)
    if suffix == 'm4a':
        audio = MP4(path)
        audio['sonm'] = ['Title Sort']
        audio['soar'] = ['Artist Sort']
        audio['soal'] = ['Album Sort']
        audio['soaa'] = ['Album Artist Sort']
        audio['soco'] = ['Composer Sort']
        audio['tmpo'] = [123]
        audio.save()
path = root / 'Folder Artist' / 'Fallback Album' / '07 - Fallback.mp3'
path.parent.mkdir(parents=True, exist_ok=True)
subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', 'sine=frequency=220:duration=1',
                '-c:a', 'libmp3lame', str(path)], check=True)

subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', 'color=red:s=16x16',
                '-frames:v', '1', str(root / 'test-cover.png')], check=True)
