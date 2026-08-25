# Third-party notices

## Chess piece artwork

The Staunton piece vectors rendered by `chess/UI/PieceArt.swift` are derived
from the SVG chess pieces drawn by Wikimedia Commons user **Cburnett** — the
same set Wikipedia and lichess render.

* Source: <https://commons.wikimedia.org/wiki/Category:SVG_chess_pieces>
* The author offers the files under a choice of four licences (GFDL, BSD,
  GPL and CC BY-SA 3.0). They are used here under the **BSD** licence,
  reproduced in full below as that licence requires.

The SVGs were flattened offline — inherited styles resolved, transforms baked
into the geometry and arcs converted to cubics — which leaves path data using
only absolute `M` / `L` / `C` / `Z` commands in the original 45×45 design box.
The artwork itself is unmodified.

### BSD licence

```
Copyright (c) 2006 Colin M.L. Burnett

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice,
   this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.
3. The name of the author may not be used to endorse or promote products
   derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR IMPLIED
WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO
EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS;
OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR
OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

The same attribution is shown to players in the app under **Settings →
Credits**.

## Everything else

All other code and assets in this repository — the engine, the AI, the game
review, the tutorial and the synthesized sounds — are original to this
project. No third-party packages are used; the app links only Apple's own
frameworks.
