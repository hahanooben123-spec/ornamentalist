# Lokal testversion 0.14.1, build 44

Ved klargøring af denne version er Apple-kompilering og native pixeltests endnu ikke kørt. Se GitHub Actions for efterfølgende resultater. Lokal Swift-grammatikkontrol, kildefilsoversigt og ZIP-indhold er kontrolleret. Ingen målt iPad-hastighedsgevinst hævdes.

## Ændringer

- Zoom anvender den nyeste forespørgsel efter en kort inputpause, prioriterer centrale felter og viser felter efterhånden. Resten af et forældet udsnit afbrydes mellem felter; ved stor bevægelse kasseres det gamle felt.
- Lærred, zoom og eksport deler én begrænset LRU-pulje af uforanderlige strøgbuffere. En isoleret lagforhåndsvisning må ikke beskære lærredets pulje. Samtidige genopbygninger beskytter deres nødvendige buffere mod udskiftning.
- Konservative skærmgrænser frasorterer usynlige strøg før genopbygning. GPU-instanslisten frasorterer også usynlige Mirror-, radial- og tilekopier uden at ændre deres rækkefølge. Prikstørrelse, tilt og antialiasing er med i sikkerhedsmargenerne.
- Eksport bruger en genanvendelig GPU-læseflade og CPU-læsebuffer. Pixeloverførsel, samling af eksportfelter og tabsfri PNG-kodning kører på eksportaktøren. Store arbejdsflader frigives efter eksport og ved annullering.
- Opvarmning af galleri-forhåndsvisning afbrydes, mens der tegnes eller navigeres, og planlægges igen bagefter.
- Fortryd-beregningen tæller delte samplebuffere og billedpayloads én gang. Grænserne på 24 MiB/100 handlinger og 8 MiB under hukommelsespres er bevaret.
- Tidligere lokale rettelser til paneler, sidste pensel pr. kategori og hold-for-bue er inkluderet.

## Kontrol på iPad

1. Zoom, panorér og rotér en detaljeret mandala med Mirror og bløde skygger. Se efter manglende streger, feltsamlinger og reaktionstid.
2. Eksportér original størrelse, 4096 px og A4; sammenlign skygger, transparens og prikker, især ved felternes samlinger. Kontrollér også annullering og ny eksport bagefter.
3. Fortryd/gentag flere lagændringer med et importeret billede. Kontrollér indhold og historikkens tilgængelighed.

Der er tilføjet automatiske kontroltilfælde for synlighed, delt geometri, billedlighed, fortryd-ejerskab og udskydelse af forhåndsvisninger. De er ikke kørt i denne lokale Windows-session.
