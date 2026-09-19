"""Dump the parts of a binary FBX that decide orientation: GlobalSettings axes,
every Model node's local transform, and per-geometry vertex bbox plus a count of
polygons whose STORED normal disagrees with the normal implied by their winding.
Pure Python, no Blender. Usage: python fbxdump.py a.fbx [b.fbx ...]"""
import struct, sys, zlib


def read_props(buf, pos, count):
    props = []
    for _ in range(count):
        t = chr(buf[pos]); pos += 1
        if t == 'Y':
            props.append(struct.unpack_from('<h', buf, pos)[0]); pos += 2
        elif t == 'C':
            props.append(bool(buf[pos])); pos += 1
        elif t == 'I':
            props.append(struct.unpack_from('<i', buf, pos)[0]); pos += 4
        elif t == 'F':
            props.append(struct.unpack_from('<f', buf, pos)[0]); pos += 4
        elif t == 'D':
            props.append(struct.unpack_from('<d', buf, pos)[0]); pos += 8
        elif t == 'L':
            props.append(struct.unpack_from('<q', buf, pos)[0]); pos += 8
        elif t in 'fdlib':
            n, enc, clen = struct.unpack_from('<III', buf, pos); pos += 12
            raw = buf[pos:pos + clen]; pos += clen
            if enc == 1:
                raw = zlib.decompress(raw)
            fmt = {'f': 'f', 'd': 'd', 'l': 'q', 'i': 'i', 'b': 'b'}[t]
            props.append(list(struct.unpack('<%d%s' % (n, fmt), raw)))
        elif t in 'SR':
            n = struct.unpack_from('<I', buf, pos)[0]; pos += 4
            raw = buf[pos:pos + n]; pos += n
            props.append(raw.decode('latin-1') if t == 'S' else raw)
        else:
            raise ValueError('prop type %r at %d' % (t, pos))
    return props, pos


def read_node(buf, pos, big):
    if big:
        end, nprops, plen = struct.unpack_from('<QQQ', buf, pos); pos += 24
    else:
        end, nprops, plen = struct.unpack_from('<III', buf, pos); pos += 12
    nlen = buf[pos]; pos += 1
    if end == 0:
        return None, pos
    name = buf[pos:pos + nlen].decode('latin-1'); pos += nlen
    props, pos = read_props(buf, pos, nprops)
    children = []
    while pos < end:
        child, pos = read_node(buf, pos, big)
        if child is None:
            break
        children.append(child)
    return (name, props, children), end


def parse(path):
    buf = open(path, 'rb').read()
    assert buf[:20] == b'Kaydara FBX Binary  ', 'not binary fbx'
    version = struct.unpack_from('<I', buf, 23)[0]
    big = version >= 7500
    pos = 27
    top = []
    while pos < len(buf):
        node, pos = read_node(buf, pos, big)
        if node is None:
            break
        top.append(node)
    return version, top


def find(nodes, name):
    return [n for n in nodes if n[0] == name]


def p70(node):
    out = {}
    for c in node[2]:
        if c[0] == 'Properties70':
            for p in c[2]:
                if p[0] == 'P':
                    out[p[1][0]] = p[1][4:]
    return out


def cross(a, b):
    return (a[1]*b[2]-a[2]*b[1], a[2]*b[0]-a[0]*b[2], a[0]*b[1]-a[1]*b[0])


def sub(a, b):
    return (a[0]-b[0], a[1]-b[1], a[2]-b[2])


def dot(a, b):
    return a[0]*b[0]+a[1]*b[1]+a[2]*b[2]


def geometry_report(g):
    verts = find(g[2], 'Vertices')[0][1][0]
    idx = find(g[2], 'PolygonVertexIndex')[0][1][0]
    V = [tuple(verts[i:i+3]) for i in range(0, len(verts), 3)]
    xs, ys, zs = zip(*V)
    polys, cur = [], []
    for i in idx:
        if i < 0:
            cur.append(~i); polys.append(cur); cur = []
        else:
            cur.append(i)
    rep = {'verts': len(V), 'polys': len(polys),
           'bbox_min': tuple(round(min(a), 3) for a in (xs, ys, zs)),
           'bbox_max': tuple(round(max(a), 3) for a in (xs, ys, zs))}
    ln = find(g[2], 'LayerElementNormal')
    if ln:
        ln = ln[0]
        mapping = find(ln[2], 'MappingInformationType')[0][1][0]
        reference = find(ln[2], 'ReferenceInformationType')[0][1][0]
        normals = find(ln[2], 'Normals')[0][1][0]
        N = [tuple(normals[i:i+3]) for i in range(0, len(normals), 3)]
        if reference == 'IndexToDirect':
            nidx = find(ln[2], 'NormalsIndex')[0][1][0]
            N = [N[i] for i in nidx]
        rep['normal_mapping'] = mapping + '/' + reference
        rep['normals'] = len(N)
        if mapping == 'ByPolygonVertex':
            agree = disagree = flat = 0
            c = 0
            for poly in polys:
                a, b, d = V[poly[0]], V[poly[1]], V[poly[2]]
                gn = cross(sub(b, a), sub(d, a))
                # stored normal averaged over the polygon's corners
                sn = [0.0, 0.0, 0.0]
                for k in range(len(poly)):
                    n = N[c + k]
                    sn[0] += n[0]; sn[1] += n[1]; sn[2] += n[2]
                c += len(poly)
                dd = dot(gn, sn)
                if dd > 0: agree += 1
                elif dd < 0: disagree += 1
                else: flat += 1
            rep['winding_vs_stored_normal'] = {'agree': agree, 'disagree': disagree, 'degenerate': flat}
    return rep


def report(path):
    version, top = parse(path)
    print('=' * 100)
    print(path, 'version', version)
    gs = find(top, 'GlobalSettings')[0]
    props = p70(gs)
    keys = ['UpAxis', 'UpAxisSign', 'FrontAxis', 'FrontAxisSign', 'CoordAxis', 'CoordAxisSign',
            'OriginalUpAxis', 'OriginalUpAxisSign', 'UnitScaleFactor', 'OriginalUnitScaleFactor']
    print('  GlobalSettings:', {k: props[k][0] if k in props else None for k in keys})
    objects = find(top, 'Objects')[0]
    models = find(objects[2], 'Model')
    print('  Models:', len(models))
    for m in models:
        name = m[1][1].split('\x00')[0]
        kind = m[1][2]
        pp = p70(m)
        t = pp.get('Lcl Translation'); r = pp.get('Lcl Rotation'); s = pp.get('Lcl Scaling')
        pre = pp.get('PreRotation')
        interesting = kind != 'LimbNode' or name in ('Bip01', 'Bip01_Pelvis', 'Bip01_Spine', 'Bip01_Head', 'Bip01_L_UpperArm', 'Bip01_R_UpperArm', 'Bip01_L_Foot', 'Bip01_R_Foot')
        if interesting:
            fmt = lambda v: tuple(round(x, 3) for x in v) if v else None
            print('   %-28s %-9s T=%s R=%s S=%s pre=%s' % (name, kind, fmt(t), fmt(r), fmt(s), fmt(pre)))
    limbs = [m[1][1].split('\x00')[0] for m in models if m[1][2] == 'LimbNode']
    print('  LimbNodes:', len(limbs))
    for g in find(objects[2], 'Geometry'):
        if g[1][2] != 'Mesh':
            continue
        print('  Geometry', g[1][1].split('\x00')[0], geometry_report(g))


def geometries(path):
    _v, top = parse(path)
    objects = find(top, 'Objects')[0]
    out = []
    for g in find(objects[2], 'Geometry'):
        if g[1][2] != 'Mesh':
            continue
        verts = find(g[2], 'Vertices')[0][1][0]
        idx = find(g[2], 'PolygonVertexIndex')[0][1][0]
        V = [tuple(verts[i:i+3]) for i in range(0, len(verts), 3)]
        polys, cur = [], []
        for i in idx:
            if i < 0:
                cur.append(~i); polys.append(cur); cur = []
            else:
                cur.append(i)
        out.append((g[1][1].split('\x00')[0], V, polys))
    return out


def compare(a, b):
    """Same vertex order assumed (same source, same fit). Reports how many
    vertices match exactly, match under a single-axis negation, and how many
    polygons have identical vs reversed winding."""
    ga, gb = geometries(a)[0], geometries(b)[0]
    _na, Va, Pa = ga
    _nb, Vb, Pb = gb
    print('=' * 100)
    print('COMPARE', a, '\n     vs', b)
    print('  verts %d vs %d, polys %d vs %d' % (len(Va), len(Vb), len(Pa), len(Pb)))
    if len(Va) != len(Vb):
        # order-free: match by rounded position
        sa = set(tuple(round(c, 4) for c in v) for v in Va)
        sb = set(tuple(round(c, 4) for c in v) for v in Vb)
        for label, fn in (('identity', lambda v: v), ('neg x', lambda v: (-v[0], v[1], v[2])),
                          ('neg y', lambda v: (v[0], -v[1], v[2])), ('neg z', lambda v: (v[0], v[1], -v[2]))):
            hit = sum(1 for v in sb if tuple(round(c, 4) for c in fn(v)) in sa)
            print('  position-set overlap under %-8s: %d / %d' % (label, hit, len(sb)))
        return
    tol = 1e-4
    def close(u, v):
        return all(abs(x - y) < tol for x, y in zip(u, v))
    same = sum(1 for u, v in zip(Va, Vb) if close(u, v))
    nx = sum(1 for u, v in zip(Va, Vb) if close(u, (-v[0], v[1], v[2])))
    ny = sum(1 for u, v in zip(Va, Vb) if close(u, (v[0], -v[1], v[2])))
    nz = sum(1 for u, v in zip(Va, Vb) if close(u, (v[0], v[1], -v[2])))
    print('  vertices identical: %d   under neg x: %d   neg y: %d   neg z: %d' % (same, nx, ny, nz))
    if len(Pa) == len(Pb):
        ident = rev = other = 0
        for p, q in zip(Pa, Pb):
            if p == q:
                ident += 1
            elif len(p) == len(q) and any(q == p[i:] + p[:i] for i in range(len(p))):
                ident += 1
            elif len(p) == len(q) and any(list(reversed(q)) == p[i:] + p[:i] for i in range(len(p))):
                rev += 1
            else:
                other += 1
        print('  polygons same winding: %d   reversed: %d   other: %d' % (ident, rev, other))


args = sys.argv[1:]
if args and args[0] == '--compare':
    compare(args[1], args[2])
else:
    for p in args:
        report(p)
