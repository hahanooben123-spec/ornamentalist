# Pensler — version 0.4.0

Åbn **Brushes** nederst i studiet. Vælg en kategori og tryk på en pensel. Hver række viser et rigtigt eksempel på penslens strøg. Øverst vises den valgte pensel med dine aktuelle indstillinger. Rul ned i panelet for at justere den; lukkeknappen bliver øverst.

- **Ink:** Fineliner, Brush pen, Round marker og Flat marker. Fineliner giver den oprindelige ensartede streg; Brush pen har som standard trykfølsom bredde. Markerne bygger transparent tone med runde eller flade aftryk.
- **Shading:** Soft shader og Airbrush. Begge har gradvist bløde kanter. Airbrush starter bredere og svagere. Tegn flere passager for mørkere skygger.
- **Dots:** Dots, Fine dots, Light stipple, Dense stipple og Dot shader. Dots/Fine dots laver adskilte prikker langs bevægelsen; et kort tryk laver én prik. Stipple spreder prikker inden for penslens område. Dot shader samler flest prikker i midten til en blød, prikket skygge.
- **Texture:** Graphite, Charcoal og Hatching. Graphite bruger fint korn, Charcoal større korn, og Hatching korte parallelle mærker til skraveret skygge.

## Indstillinger

**Size** går fra 0,5 til 160 lærredspixels. Ved stipple og tekstur er det størrelsen på området, der spredes indenfor; prikkerne er mindre end området. **Opacity** styrer hvert aftryk i marker-, skygge-, prik- og teksturpenslerne. Lavere værdi giver lettere opbygning ved gentagne passager. Fineliner og Brush pen er dækkende blæk.

**Spacing** er afstanden mellem aftryk i procent af penselstørrelsen. Høj afstand giver luft mellem prikker; lav afstand giver flere aftryk og mørkere passager. **Density** bestemmer antallet af små mærker per aftryk i stipple- og teksturpenslerne. **Pressure sensitivity** varierer størrelsen med Pencil-trykket; **Steady line** udglatter bevægelsen.

Penslerne følger bevægelsens afstand, ikke skærmens billedhastighed. At holde Pencil helt stille sprayer derfor ikke flere prikker oven på hinanden. Bevæg penslen eller tegn flere passager for at bygge tone. Et nyt preset indlæser sine egne standardindstillinger; ændringer gælder kun næste strøg.

## Mirror, lag og filer

Alle pensler bruger de eksisterende symmetri- og lagfunktioner. Et strøg beholder sin pensel, styrke, afstand, tæthed, symmetri og lag. Tilfældige mønstre udledes af strøgets gemte identitet og afstandsindeks, så de samme prikker vender tilbage ved genåbning, Undo/Redo, Mirror og eksport.

PNG og miniaturebilleder indeholder de synlige lag og penslernes gennemsigtighed; hjælpelinjer og forudsagte Pencil-punkter eksporteres ikke. Bløde kanter beregnes med samme faldkurve i Metal og Core Graphics; kantudjævning kan give små pixelforskelle.

Version 0.4.0 gemmer dokumentformat **4**. Ældre projekter kan importeres og bevarer deres oprindelige fineliner-geometri. Filer gemt i format 4 kræver den nye app. Tag en redigerbar projektkopi fra eksportmenuen, før du udskifter dit Playground-projekt.

Penslerne er procedurebaserede sorte pensler. Import af eksterne penselpakker og redigering af egne presets er ikke med i denne version.
