# Decodes what gen.mjs wrote with two independent OpenCV detectors; a wrong text is printed as WRONG.
import json, sys, cv2
lst = json.load(open(sys.argv[1]))
dets = [('std', cv2.QRCodeDetector())]
if hasattr(cv2, 'QRCodeDetectorAruco'): dets.append(('aruco', cv2.QRCodeDetectorAruco()))
for name, d in dets:
    ok = 0; bad = []
    for e in lst:
        img = cv2.imread(e['f'], cv2.IMREAD_GRAYSCALE)
        got = False
        for sc in (1.0, 0.5, 0.375, 0.25):
            im = img if sc == 1.0 else cv2.resize(img, None, fx=sc, fy=sc, interpolation=cv2.INTER_AREA)
            txt, pts, _ = d.detectAndDecode(im)
            if txt == e['t']: got = True; break
            if txt and txt != e['t']: print(name, 'WRONG', e['version'], e['mk'], repr(txt[:30])); break
        ok += got
        if not got: bad.append((e['version'], e['mk']))
    print(name, f'{ok}/{len(lst)}', 'missed', bad)
