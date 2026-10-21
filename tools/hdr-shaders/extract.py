"""Writes the HLSL programs embedded in libs/scrap/src/dxgi/hdr.rs to .hlsl
files, composed the same way hdr.rs composes them, so CI can run fxc on them."""
import pathlib, re, sys

src = pathlib.Path(sys.argv[1]).read_text()
out = pathlib.Path(sys.argv[2])
out.mkdir(parents=True, exist_ok=True)
consts = {}
for name, body in re.findall(r'const (\w+): &str = "(.*?)";', src, re.S):
    consts[name] = re.sub(r'\\\n\s*', '', body)
programs = {
    'vs': consts['VS_SRC'],
    'ps_sdr': consts['PS_SRC'],
}
for s in ('FLOAT', 'SRGB'):
    for p in ('Y', 'UV'):
        programs[f'ps_pq_{s.lower()}_{p.lower()}'] = consts['PQ_COMMON'] + consts[f'PQ_SRC_{s}'] + consts[f'PQ_PLANE_{p}']
for name, text in programs.items():
    (out / f'{name}.hlsl').write_text(text)
    print(name)
