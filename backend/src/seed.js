const bcrypt = require('bcryptjs');
const { db, transaction } = require('./db');
const { normalizePhone } = require('./auth');

// Carte de KALETA — Terrasse & Lounge (Lomé, face au lycée d'Agoè), d'après le menu officiel du restaurant
// (menukaleta.netlify.app). Prix en FCFA ; pour les plats en deux tailles, le prix de la grande portion.
const U = (id) => `https://images.unsplash.com/photo-${id}?w=800`;

const CATEGORIES = [
  { name: 'Menu du jour', icon: 'daily' },
  { name: 'Signatures Kaleta', icon: 'star' },
  { name: "Cuisine d'Afrique", icon: 'african' },
  { name: 'Brochettes & grillades', icon: 'grill' },
  { name: 'Viandes & poissons', icon: 'fish' },
  { name: 'Pizzas au feu de bois', icon: 'pizza' },
  { name: 'Burgers & chawarmas', icon: 'burger' },
  { name: 'Spaghettis & pâtes', icon: 'pasta' },
  { name: 'Entrées & salades', icon: 'salad' },
  { name: 'Accompagnements', icon: 'fries' },
  { name: "Petit déj' & desserts", icon: 'dessert' },
  { name: 'Jus & thés Kaleta', icon: 'juice' },
  { name: 'Cocktails & mocktails', icon: 'cocktail' },
  { name: 'Bières & sodas', icon: 'beer' },
  { name: 'Vins & champagnes', icon: 'wine' },
  { name: 'Chicha', icon: 'chicha' },
  { name: 'Packs', icon: 'pack' },
];
const C = Object.fromEntries(CATEGORIES.map((c, i) => [c.name, i]));

// Packs : [nom, description, prix FCFA, populaire, image, [[nom du plat, quantité], ...]]
const PACKS = [
  ['Pack Solo', 'Tilapia braisé, attiéké et bissap pour une personne', 10000, 1, U('1510130387422-82bed34b37e9'),
    [['Tilapia braisé', 1], ['Attiéké', 1], ['Bissap', 1]]],
  ['Pack Duo Lounge', 'Pour deux : brochettes de poulet, alloco et deux Kaleta Sunset', 20000, 1, U('1555939594-58d7cb561ad1'),
    [['Brochette de poulet', 2], ['Alloco', 2], ['Kaleta Sunset', 2]]],
  ['Pack Rooftop', 'Pizza Kaleta, chicha Love et deux mojitos : la soirée est lancée', 20000, 0, U('1574071318508-1cdbab80d002'),
    [['Pizza Kaleta', 1], ['Chicha Love', 1], ['Mojito', 2]]],
  ['Pack Famille Afrique', 'Poulet DG, tilapia braisé, attiéké, alloco et bissap pour 4', 35000, 1, U('1598103442097-8b74394b95c6'),
    [['Poulet DG', 1], ['Tilapia braisé', 1], ['Attiéké', 4], ['Alloco', 2], ['Bissap', 4]]],
];

// [catégorie, nom, description, prix FCFA, populaire, image (null = sans photo)]
const PRODUCTS = [
  // Menu du jour : le nom commence par le jour (l'app met en avant ceux du jour).
  [C['Menu du jour'], 'Lundi · Sauce adémè + poisson frit', 'Sauce adémè (crincrin), poisson frit et accompagnement au choix', 4000, 0, U('1604329760661-e71dc83f8f26')],
  [C['Menu du jour'], 'Lundi · Sauce tomate + poulet', 'Sauce tomate maison, poulet et accompagnement au choix', 4000, 0, U('1574484284002-952d92456975')],
  [C['Menu du jour'], 'Lundi · Spaghetti Kaleta', 'Spaghetti au poisson séché et légumes', 3000, 0, U('1563379926898-05f4575a45d8')],
  [C['Menu du jour'], 'Mardi · Demi-poisson braisé + alloco', 'Demi-poisson braisé, alloco', 4000, 0, U('1467003909585-2f8a72700288')],
  [C['Menu du jour'], 'Mardi · Sauce + viande + riz au gras', 'Sauce du jour, morceau de viande, riz au gras', 4000, 0, U('1568096889942-6eedde686635')],
  [C['Menu du jour'], 'Mardi · Poulet braisé + attiéké', 'Poulet braisé, attiéké et crudités', 5500, 0, U('1598103442097-8b74394b95c6')],
  [C['Menu du jour'], 'Mercredi · Sauce arachide + foufou', 'Sauce arachide, viande et foufou', 4000, 0, U('1604329760661-e71dc83f8f26')],
  [C['Menu du jour'], 'Mercredi · Poulet sauté + koliko', 'Poulet sauté, koliko (igname frite)', 3000, 0, U('1598103442097-8b74394b95c6')],
  [C['Menu du jour'], 'Mercredi · Spaghetti bolognaise', 'Sauce bolognaise maison, fromage râpé', 3000, 0, U('1621996346565-e3dbc646d9a9')],
  [C['Menu du jour'], 'Jeudi · Poisson frit + akpan', 'La formule légère : poisson frit et akpan', 2000, 0, U('1580476262798-bddd9f4b7369')],
  [C['Menu du jour'], 'Jeudi · Sauce graine + bœuf', 'Sauce graine, bœuf et accompagnement au choix', 4000, 0, U('1568096889942-6eedde686635')],
  [C['Menu du jour'], 'Jeudi · Viande + igname sautée', 'Viande et igname sautée aux légumes', 3000, 0, U('1504674900247-0877df9cc836')],
  [C['Menu du jour'], 'Vendredi · Sauce arachide + poulet', 'Sauce arachide, poulet et accompagnement au choix', 4000, 0, U('1574484284002-952d92456975')],
  [C['Menu du jour'], 'Vendredi · Poisson braisé + attiéké', 'Poisson braisé, attiéké et crudités', 5500, 0, U('1510130387422-82bed34b37e9')],
  [C['Menu du jour'], 'Vendredi · Pizza Kaleta (mini)', 'La pizza signature en format mini', 3000, 0, U('1565299624946-b28f40a0ae38')],
  [C['Menu du jour'], 'Samedi · Brochettes + frites', 'Brochettes grillées et frites', 5000, 0, U('1555939594-58d7cb561ad1')],
  [C['Menu du jour'], 'Samedi · Poulet + petits poissons + riz Kaleta', 'Poulet, petits poissons et riz Kaleta', 8000, 0, U('1568096889942-6eedde686635')],
  [C['Menu du jour'], 'Samedi · Kaleta Burger + frites', 'Le burger signature et ses frites', 5000, 0, U('1586190848861-99aa4a171e90')],
  [C['Menu du jour'], 'Dimanche · Sauce graine + foutou banane', 'Sauce graine, viande et foutou banane', 6000, 0, U('1604329760661-e71dc83f8f26')],
  [C['Menu du jour'], 'Dimanche · Demi-poisson + akpan Kaleta', 'Demi-poisson et akpan Kaleta', 5000, 0, U('1611171711912-e3f6b536f532')],
  [C['Menu du jour'], 'Dimanche · Poisson braisé + attiéké', 'Poisson braisé, attiéké et crudités', 5000, 0, U('1510130387422-82bed34b37e9')],

  // Signatures du chef.
  [C['Signatures Kaleta'], 'Salade Kaleta', 'La salade signature du chef : composition généreuse et raffinée', 10000, 1, U('1625944230945-1b7dd3b949ab')],
  [C['Signatures Kaleta'], 'Pizza Kaleta', 'Création signature cuite au feu de bois (grande)', 10000, 1, U('1574071318508-1cdbab80d002')],
  [C['Signatures Kaleta'], 'Brochette Kaleta', 'Assortiment de brochettes marinées, grillées au feu de bois', 10000, 1, U('1555939594-58d7cb561ad1')],
  [C['Signatures Kaleta'], 'Kaleta Burger', 'Le burger de la maison, servi avec frites', 5000, 1, U('1586190848861-99aa4a171e90')],
  [C['Signatures Kaleta'], 'Chawarma Kaleta', 'Chawarma généreux façon Kaleta, frites', 5000, 0, U('1529042410759-befb1204b468')],
  [C['Signatures Kaleta'], 'Spaghetti Kaleta', 'Spaghetti signature aux saveurs de la maison', 5000, 0, U('1563379926898-05f4575a45d8')],

  // Cuisine d'Afrique : 8 pays.
  [C["Cuisine d'Afrique"], 'Ayimolou complet', 'Togo · Riz-haricot, œuf, poisson et spaghetti', 2000, 1, U('1512058564366-18510be2db19')],
  [C["Cuisine d'Afrique"], 'Fufu sauce arachide', 'Togo · Sauce blanche ou rouge pimentée, viande au choix', 5000, 1, U('1604329760661-e71dc83f8f26')],
  [C["Cuisine d'Afrique"], 'Adémè / fétri + akoumé', 'Togo · Pâte et sauce au choix (3 morceaux minimum)', 5000, 0, U('1604329760661-e71dc83f8f26')],
  [C["Cuisine d'Afrique"], 'Sauce tomate-piment + koliko', 'Togo · Igname frite traditionnelle, sauce tomate-piment', 3000, 0, U('1574484284002-952d92456975')],
  [C["Cuisine d'Afrique"], 'Sifio', 'Togo · Tilapia mijoté aux légumes, pâte de gari', 12000, 0, U('1485921325833-c519f76c4927')],
  [C["Cuisine d'Afrique"], 'Demi-poulet braisé + riz au gras', 'Bénin · Riz jaune épicé, demi-poulet braisé', 5000, 1, U('1598103442097-8b74394b95c6')],
  [C["Cuisine d'Afrique"], 'Ailerons de poulet + amiwo', 'Bénin · Pâte rouge à la tomate, ailerons braisés', 5000, 0, U('1544025162-d76694265947')],
  [C["Cuisine d'Afrique"], 'Atassi', 'Bénin · Riz et haricots cuits ensemble', 2000, 0, U('1512058564366-18510be2db19')],
  [C["Cuisine d'Afrique"], 'Garba poisson', "Côte d'Ivoire · Attiéké et poisson frit au choix", 5000, 1, U('1580476262798-bddd9f4b7369')],
  [C["Cuisine d'Afrique"], 'Foutou banane sauce graine', "Côte d'Ivoire · Purée de banane, sauce graine et 2 viandes", 5000, 0, U('1568096889942-6eedde686635')],
  [C["Cuisine d'Afrique"], 'Tilapia braisé + alloco', "Côte d'Ivoire · Tilapia entier braisé, bananes plantain frites", 8000, 0, U('1467003909585-2f8a72700288')],
  [C["Cuisine d'Afrique"], 'Sauce gombo + akpan', 'Ghana · Sauce gombo (4 morceaux), pâte de maïs fermenté', 5000, 0, U('1604329760661-e71dc83f8f26')],
  [C["Cuisine d'Afrique"], 'Indomie', 'Ghana · Nouilles sautées maison', 5000, 0, U('1612874742237-6526221588e3')],
  [C["Cuisine d'Afrique"], 'Thiep', 'Sénégal · Riz au poisson, version rouge ou blanche', 5000, 1, U('1485921325833-c519f76c4927')],
  [C["Cuisine d'Afrique"], 'Dibi (choukouya)', 'Sénégal · Viande grillée épicée, plateau à partager', 10000, 0, U('1529692236671-f1f6cf9683ba')],
  [C["Cuisine d'Afrique"], 'Gombo + pâte de gari', 'Cameroun · Spécialité traditionnelle', 5000, 0, U('1604329760661-e71dc83f8f26')],
  [C["Cuisine d'Afrique"], 'Suya brochette', 'Nigeria · Brochettes épicées façon haoussa', 5000, 0, U('1555939594-58d7cb561ad1')],
  [C["Cuisine d'Afrique"], 'Jollof rice', 'Nigeria · Riz jollof épicé', 5000, 1, U('1568096889942-6eedde686635')],

  // Brochettes & grillades (feu de bois).
  [C['Brochettes & grillades'], 'Brochette saucisse', 'Saucisse grillée', 2000, 0, U('1555939594-58d7cb561ad1')],
  [C['Brochettes & grillades'], 'Brochette de gésier', '3 brochettes, accompagnement au choix', 4000, 0, U('1555939594-58d7cb561ad1')],
  [C['Brochettes & grillades'], 'Brochette de poulet', '3 brochettes marinées, accompagnement au choix', 5000, 1, U('1555939594-58d7cb561ad1')],
  [C['Brochettes & grillades'], "Brochette d'ailerons", 'Ailerons de poulet marinés aux épices', 5000, 0, U('1544025162-d76694265947')],
  [C['Brochettes & grillades'], 'Brochette de poisson', '3 brochettes, accompagnement au choix', 6000, 0, U('1599487488170-d11ec9c172f0')],
  [C['Brochettes & grillades'], 'Brochette de bœuf', '3 brochettes, accompagnement au choix', 8000, 0, U('1529692236671-f1f6cf9683ba')],
  [C['Brochettes & grillades'], 'Pintade sautée aux légumes', 'Pintade tendre, légumes du jardin', 12000, 0, U('1598103442097-8b74394b95c6')],
  [C['Brochettes & grillades'], 'Poulet DG', 'Poulet sauté à la camerounaise, plantain et légumes', 15000, 1, U('1598103442097-8b74394b95c6')],
  [C['Brochettes & grillades'], 'Soupe de pêcheur', 'Bouillabaisse togolaise, poissons et fruits de mer du Golfe', 15000, 0, U('1485921325833-c519f76c4927')],

  // Viandes & poissons (accompagnement compris).
  [C['Viandes & poissons'], 'Tilapia braisé', 'Tilapia entier au feu de bois, accompagnement au choix', 8000, 1, U('1510130387422-82bed34b37e9')],
  [C['Viandes & poissons'], 'Bœuf sauté', 'Bœuf sauté aux légumes', 8000, 0, U('1504674900247-0877df9cc836')],
  [C['Viandes & poissons'], "Côte d'agneau", "Côte d'agneau grillée aux herbes", 8000, 0, U('1432139555190-58524dae6a55')],
  [C['Viandes & poissons'], 'Mouton braisé', "Marinade aux épices d'Afrique de l'Ouest", 8000, 0, U('1529692236671-f1f6cf9683ba')],
  [C['Viandes & poissons'], 'Gambas', 'Crevettes grillées, sauce beurre à l\'ail (6 pièces)', 10000, 0, U('1563379926898-05f4575a45d8')],
  [C['Viandes & poissons'], 'Steak de bœuf', 'Filet de bœuf, gratin de pommes de terre', 10000, 0, U('1600891964092-4316c288032e')],

  // Pizzas au feu de bois (grande ; mini sur place).
  [C['Pizzas au feu de bois'], 'Pizza Margherita', 'Sauce tomate, fromage, basilic', 5000, 0, U('1574071318508-1cdbab80d002')],
  [C['Pizzas au feu de bois'], 'Pizza Royale', 'Tomate fraîche, viande hachée, champignons, poivron, fromage, olives', 5000, 1, U('1513104890138-7c749659a591')],
  [C['Pizzas au feu de bois'], 'Pizza Reine', 'Sauce tomate, jambon, fromage, champignons, crème fraîche, olives', 5000, 0, U('1565299624946-b28f40a0ae38')],
  [C['Pizzas au feu de bois'], 'Pizza Végétarienne', 'Maïs, champignons, fromage, tomate, cornichons, olives, basilic', 5000, 0, U('1513104890138-7c749659a591')],
  [C['Pizzas au feu de bois'], 'Pizza au Thon', 'Sauce tomate, thon, fromage, basilic, tomate fraîche', 8000, 0, U('1565299624946-b28f40a0ae38')],

  // Burgers & chawarmas (servis avec frites).
  [C['Burgers & chawarmas'], 'Hamburger', 'Steak, frites, salade, tomate, oignon, sauce cocktail', 2000, 0, U('1568901346375-23c9450c58cd')],
  [C['Burgers & chawarmas'], 'Chawarma poulet', 'Pain libanais, frites, coleslaw, sauce cocktail', 2000, 1, U('1529042410759-befb1204b468')],
  [C['Burgers & chawarmas'], 'Cheese burger', 'Steak, fromage, frites, tomate, oignon, sauce, salade', 3000, 0, U('1571091718767-18b5b1457add')],
  [C['Burgers & chawarmas'], 'Double cheese burger', '2 steaks, 2 fromages, frites, oignons sautés, sauce', 4000, 0, U('1550547660-d9450f859349')],
  [C['Burgers & chawarmas'], 'Frite sandwich', 'Poisson ou bœuf, frites, tomate, oignon, salade, mayonnaise', 5000, 0, U('1568901346375-23c9450c58cd')],

  // Spaghettis & pâtes.
  [C['Spaghettis & pâtes'], 'Spaghetti rouge', 'Sauce tomate, bœuf, oignon, piment vert, poivron', 5000, 0, U('1621996346565-e3dbc646d9a9')],
  [C['Spaghettis & pâtes'], 'Spaghetti aux légumes', 'Carotte, haricots verts, poivron, oignon, bœuf ou poulet', 5000, 0, U('1563379926898-05f4575a45d8')],
  [C['Spaghettis & pâtes'], 'Spaghetti crème fraîche', 'Crème fraîche, légumes, bœuf ou poulet', 5000, 0, U('1612874742237-6526221588e3')],
  [C['Spaghettis & pâtes'], 'Spaghetti bolognaise', 'Sauce bolognaise maison, fromage râpé', 5000, 0, U('1621996346565-e3dbc646d9a9')],

  // Entrées & salades.
  [C['Entrées & salades'], 'Salade verte', 'Laitue, concombre, tomate, oignon', 3000, 0, U('1512621776951-a57141f2eefd')],
  [C['Entrées & salades'], 'Salade togolaise', 'Spaghetti, laitue, bœuf, œuf, oignon, tomate, betterave, carotte', 5000, 1, U('1540189549336-e6e99c3679fe')],
  [C['Entrées & salades'], 'Salade crevettes', 'Crevettes sautées, laitue, maïs, haricots, oignon, carotte', 5000, 0, U('1546069901-ba9599a7e63c')],
  [C['Entrées & salades'], 'Salade niçoise', 'Laitue, haricots verts, pomme de terre, tomate, olives noires, thon', 5000, 0, U('1505253716362-afaea1d3d1af')],
  [C['Entrées & salades'], 'Salade du chef', 'Laitue, jambon, carotte, œufs durs, tomate, concombre, fromage râpé', 5000, 0, U('1625944230945-1b7dd3b949ab')],

  // Accompagnements.
  [C['Accompagnements'], 'Attiéké', 'Semoule de manioc', 1500, 0, U('1512058564366-18510be2db19')],
  [C['Accompagnements'], 'Alloco', 'Bananes plantain frites', 1500, 0, U('1528751014936-863e6e7a319c')],
  [C['Accompagnements'], 'Frites', 'Frites maison croustillantes', 1500, 0, U('1573080496219-bb080dd4f877')],
  [C['Accompagnements'], 'Koliko', 'Igname frite', 1500, 0, null],
  [C['Accompagnements'], 'Riz au gras', 'Riz jaune ou rouge au gras', 1500, 0, null],
  [C['Accompagnements'], 'Akoumé', 'Pâte de maïs', 1500, 0, null],
  [C['Accompagnements'], 'Télibo', 'Pâte noire (cossette d\'igname)', 1500, 0, null],

  // Petit déjeuner & desserts.
  [C["Petit déj' & desserts"], 'Pain + omelette', 'Petit déjeuner', 2000, 0, U('1509440159596-0249088772ff')],
  [C["Petit déj' & desserts"], 'Café au lait + pain', 'Petit déjeuner', 2500, 0, U('1495474472287-4d71bcdd2085')],
  [C["Petit déj' & desserts"], 'Thé + croissant', 'Petit déjeuner', 4000, 0, U('1576092768241-dec231879fc3')],
  [C["Petit déj' & desserts"], 'Crêpe chocolat & caramel', 'Servie toute la journée', 1500, 1, U('1519676867240-f03562e64548')],
  [C["Petit déj' & desserts"], 'Banane flambée', 'Crème caramel', 2000, 0, U('1587314168485-3236d6710814')],
  [C["Petit déj' & desserts"], 'Panna cotta', 'Coulis fraise ou mangue', 2000, 0, U('1488477181946-6428a0291777')],
  [C["Petit déj' & desserts"], 'Salade de fruits', 'Fruits frais de saison', 1500, 0, U('1606787366850-de6330128bfc')],

  // Jus pressés & thés Kaleta.
  [C['Jus & thés Kaleta'], 'Bissap', "Jus d'hibiscus pressé à la commande", 2000, 1, U('1556679343-c7306c1976bc')],
  [C['Jus & thés Kaleta'], 'Jus de gingembre', 'Pressé à la commande', 2000, 0, U('1600271886742-f049cd451bba')],
  [C['Jus & thés Kaleta'], 'Jus de baobab', 'Pressé à la commande', 3000, 0, null],
  [C['Jus & thés Kaleta'], "Jus d'orange", 'Pressé à la commande', 2000, 0, U('1621506289937-a8e4df240d0b')],
  [C['Jus & thés Kaleta'], 'Kaleta Juice', 'Le jus signature de la maison', 5000, 1, U('1497534446932-c925b458314e')],
  [C['Jus & thés Kaleta'], 'Kaleta Milk Tea', 'Gingembre, lait, miel', 1500, 0, U('1576092768241-dec231879fc3')],
  [C['Jus & thés Kaleta'], 'Bazoukaleta', 'Gingembre, menthe, clou de girofle, cannelle, lait, miel', 2000, 0, U('1515823064-d6e0c04616a7')],

  // Cocktails & mocktails.
  [C['Cocktails & mocktails'], 'Kaleta Sunset', 'Signature Kaleta : le coucher de soleil du rooftop', 5000, 1, U('1536935338788-846bb9981813')],
  [C['Cocktails & mocktails'], 'Baobab Cream', 'Signature Kaleta', 4000, 0, U('1514362545857-3bc16c4c7d1b')],
  [C['Cocktails & mocktails'], 'Sodabi Citron', 'Signature Kaleta : sodabi et citron', 4000, 0, U('1609951651556-5334e2706168')],
  [C['Cocktails & mocktails'], 'Mojito', 'Rhum, menthe fraîche, citron, sucre, eau gazeuse', 4000, 1, U('1551538827-9c037cb4f32a')],
  [C['Cocktails & mocktails'], 'Piña Colada', 'Rhum, ananas, lait de coco, sucre de canne', 4000, 0, U('1551024709-8f23befc6f87')],
  [C['Cocktails & mocktails'], 'Tequila Sunrise', 'Tequila, jus d\'orange, sirop de grenadine', 4000, 0, U('1544145945-f90425340c7e')],
  [C['Cocktails & mocktails'], 'Virgin Mojito', 'Sans alcool : sucre de canne, citron, menthe, limonade', 3000, 0, U('1551538827-9c037cb4f32a')],
  [C['Cocktails & mocktails'], 'Bora Bora', 'Sans alcool : ananas, passion, citron, grenadine', 3000, 0, U('1497534446932-c925b458314e')],

  // Bières & sodas.
  [C['Bières & sodas'], 'Eau minérale 0,5 L', 'Bouteille', 500, 0, null],
  [C['Bières & sodas'], 'Coca-Cola', 'Canette', 1000, 0, U('1554866585-cd94860890b7')],
  [C['Bières & sodas'], 'Pils', 'Canette', 1000, 0, U('1608270586620-248524c67de9')],
  [C['Bières & sodas'], 'Guinness', 'Canette', 1500, 0, null],
  [C['Bières & sodas'], 'Heineken', 'Bouteille', 2000, 0, U('1608270586620-248524c67de9')],
  [C['Bières & sodas'], 'Red Bull', 'Canette', 2000, 0, null],

  // Vins & champagnes (bouteille).
  [C['Vins & champagnes'], 'Mouton Cadet', 'Vin rouge, bouteille', 20000, 0, U('1510812431401-41d2bd2722f3')],
  [C['Vins & champagnes'], 'JP Chenet Ice Rosé', 'Rosé, bouteille', 15000, 0, U('1510812431401-41d2bd2722f3')],
  [C['Vins & champagnes'], 'Laurent Perrier Brut', 'Champagne, bouteille', 50000, 0, null],
  [C['Vins & champagnes'], 'Moët Rosé', 'Champagne, bouteille', 60000, 0, null],

  // Chicha (terrasse et rooftop).
  [C['Chicha'], 'Chicha Love', 'Arôme Love — recharge d\'arôme 1 500 F (terrasse et rooftop)', 4000, 1, null],
  [C['Chicha'], 'Chicha Menthe', 'Arôme menthe fraîche', 4000, 0, null],
  [C['Chicha'], 'Chicha Double Melon', 'Arôme double melon', 4000, 0, null],
  [C['Chicha'], 'Chicha Miamor', 'Arôme Miamor', 4000, 0, null],
];

// Coordonnées et horaires du restaurant (Lomé = UTC+0) : lundi–jeudi 11h–23h, vendredi–dimanche 16h–02h.
const RESTAURANT_SETTINGS = {
  restaurant_phone: '+228 91 00 84 84',
  restaurant_address: "Face au lycée d'Agoè, à côté de l'OTR, Lomé",
  hours_enabled: '1',
  opening_hours: JSON.stringify({
    mon: [['00:00', '02:00'], ['11:00', '23:00']],
    tue: [['11:00', '23:00']],
    wed: [['11:00', '23:00']],
    thu: [['11:00', '23:00']],
    fri: [['16:00', '24:00']],
    sat: [['00:00', '02:00'], ['16:00', '24:00']],
    sun: [['00:00', '02:00'], ['16:00', '24:00']],
  }),
};

/**
 * Crée le compte admin (ADMIN_PHONE / ADMIN_PASSWORD). En production, sans ADMIN_PASSWORD, le mot de
 * passe par défaut est refusé : aucun admin n'est créé (le serveur démarre quand même).
 * @returns true si le compte a été créé.
 */
function createDefaultAdmin() {
  const password = process.env.ADMIN_PASSWORD || '';
  if (!password && process.env.NODE_ENV === 'production') {
    console.error(
      '❌ ADMIN_PASSWORD non défini en production : compte administrateur NON créé. ' +
        'Définissez ADMIN_PHONE et ADMIN_PASSWORD puis redémarrez le serveur.',
    );
    return false;
  }
  const phone = normalizePhone(process.env.ADMIN_PHONE || '71572566') || '71572566';
  if (db.prepare('SELECT id FROM users WHERE phone = ?').get(phone)) {
    console.error(`❌ ADMIN_PHONE ${phone} appartient déjà à un compte non administrateur : admin NON créé.`);
    return false;
  }
  // Premier compte du personnel : propriétaire (accès complet, ne peut être ni désactivé ni supprimé par un autre).
  db.prepare(`INSERT INTO users (name, phone, password_hash, role, admin_level) VALUES (?, ?, ?, 'admin', 'owner')`).run(
    'Administrateur', phone, bcrypt.hashSync(password || 'admin123', 10),
  );
  // Un mot de passe fourni par l'environnement n'est jamais écrit dans les journaux.
  console.log(
    password
      ? `👤 Compte admin créé : ${phone}`
      : `👤 Compte admin créé : ${phone} / admin123 (développement : changez le mot de passe !)`,
  );
  return true;
}

function seedIfEmpty() {
  const hasAdmin = db.prepare(`SELECT id FROM users WHERE role = 'admin' LIMIT 1`).get();
  if (!hasAdmin) createDefaultAdmin();

  const hasCategories = db.prepare('SELECT id FROM categories LIMIT 1').get();
  if (!hasCategories) {
    transaction(() => {
      // Nouvelle base : coordonnées et horaires de KALETA (sans écraser un réglage déjà fait par le gérant).
      const insertSetting = db.prepare('INSERT OR IGNORE INTO settings (key, value) VALUES (?, ?)');
      for (const [key, value] of Object.entries(RESTAURANT_SETTINGS)) {
        // Tests : horaires enregistrés mais non appliqués (sinon les commandes échoueraient la nuit).
        insertSetting.run(key, key === 'hours_enabled' && process.env.NODE_ENV === 'test' ? '0' : value);
      }

      const insertCat = db.prepare('INSERT INTO categories (name, icon, position) VALUES (?, ?, ?)');
      const ids = CATEGORIES.map((c, i) => insertCat.run(c.name, c.icon, i).lastInsertRowid);
      const insertProduct = db.prepare(
        'INSERT INTO products (category_id, name, description, price, popular, image_url) VALUES (?, ?, ?, ?, ?, ?)',
      );
      for (const [cat, name, desc, price, popular, img] of PRODUCTS) {
        insertProduct.run(ids[cat], name, desc, price, popular, img);
      }
      const idOf = (name) => db.prepare('SELECT id FROM products WHERE name = ?').get(name).id;
      const insertPack = db.prepare(
        `INSERT INTO products (category_id, name, description, price, popular, image_url, pack_items)
         VALUES (?, ?, ?, ?, ?, ?, ?)`,
      );
      const packsCat = ids[C['Packs']];
      for (const [name, desc, price, popular, img, items] of PACKS) {
        const content = items.map(([product, quantity]) => ({ product_id: Number(idOf(product)), quantity }));
        insertPack.run(packsCat, name, desc, price, popular, img, JSON.stringify(content));
      }
    });
    console.log('🎭 Carte KALETA ajoutée');
  }
}

if (require.main === module) seedIfEmpty();

module.exports = { seedIfEmpty, createDefaultAdmin, CATEGORIES, PRODUCTS, PACKS };
