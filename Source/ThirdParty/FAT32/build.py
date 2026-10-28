"""Сборка самостоятельного модуля FAT32 без установленного Commander."""
from pathlib import Path
import hashlib
import json
import os
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent
BUILD = ROOT / 'build'


def main():
    BUILD.mkdir(exist_ok=True)
    candidates = [os.environ.get('SJASMPLUS'), r'C:\z80\zuma\sjasmplus.exe', shutil.which('sjasmplus')]
    candidates = [shutil.which(p) or p for p in candidates if p]
    assembler = next((str(Path(p).resolve()) for p in candidates if Path(p).is_file()), None)
    if not assembler:
        raise SystemExit('Set SJASMPLUS to the sjasmplus executable.')
    for name,source in [('fat32','src/main.asm'),('port_sdzc','ports/sdzc.asm')]:
        command = [assembler, '--nologo', '--inc=' + str(ROOT/'src'),
                   '--inc=' + str(ROOT/'include'), '--sym=' + str(BUILD/(name+'.sym')),
                   '--lst=' + str(BUILD/(name+'.lst')), str(ROOT/source)]
        result = subprocess.run(command, cwd=ROOT, capture_output=True)
        (BUILD/(name+'.log')).write_bytes(result.stdout + result.stderr)
        print((result.stdout + result.stderr).decode('utf-8', errors='replace'))
        if result.returncode:
            raise SystemExit(result.returncode)
    image = (BUILD/'fat32.bin').read_bytes()
    work = bytearray(16384)
    port = (BUILD/'port_sdzc.bin').read_bytes()
    # Код проверок сохранности данных (src/safety.asm) исполняется в рабочей
    # странице: адреса окна берутся из символов сборки.
    sym = {m[0].strip(): int(m[1], 16) for line in (BUILD/'fat32.sym').read_text().splitlines()
           if (m := line.split(': EQU ')) and len(m) == 2}
    low = (BUILD/'fat32-low.bin').read_bytes()
    low_start, low_end = sym['FAT32_LOW_CODE'], sym['FAT32_LOW_END']
    if not (384 <= len(image) <= 16384 and len(port) <= 0x500):
        raise SystemExit('Образы драйвера не помещаются в выделенные окна памяти.')
    if not (0x2000 <= low_start and low_start + len(low) <= low_end <= 0x3000):
        raise SystemExit('Код safety.asm не помещается в рабочую страницу.')
    if any(image[slot*3] != 0xC3 for slot in range(128)):
        raise SystemExit('Повреждена фиксированная таблица JP.')
    work[low_start:low_start+len(low)] = low
    work[0x3900:0x3900+len(port)] = port
    (BUILD/'fat32-work.bin').write_bytes(work)
    (BUILD/'manifest.json').write_text(json.dumps({
        'size':len(image), 'sha256':hashlib.sha256(image).hexdigest(),
        'api_base':16384, 'api_version':1, 'command_count':128,
        'reserved_first':78, 'code_limit':32768, 'code_free_bytes':16384-len(image),
        'low_code':low_start, 'low_free_bytes':low_end-low_start-len(low),
        'zero_scratch_bytes':sym['FAT32_ZERO_SCRATCH_SIZE'],
        'filex_points':{'address':sym['FILEX_POINTS'], 'count':64, 'stride_clusters':64},
        'filex_data_cache':{'address':sym['FILEX_DATA_BUFFER'], 'size':512},
        'port_limit':0x3E00,
        'artifacts':{name:{'size':(BUILD/name).stat().st_size,
                           'sha256':hashlib.sha256((BUILD/name).read_bytes()).hexdigest()}
                     for name in ('fat32.bin','fat32-low.bin','fat32-work.bin','port_sdzc.bin')},
        'sources':{str(p.relative_to(ROOT)).replace('\\','/'):
                       hashlib.sha256(p.read_bytes()).hexdigest()
                   for p in sorted([ROOT/'build.py'] +
                       [p for d in ('src','include','ports') for p in (ROOT/d).rglob('*') if p.is_file()])},
    }, indent=2), encoding='utf-8')


if __name__ == '__main__':
    main()
