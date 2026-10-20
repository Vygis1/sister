// fpga-console enclosure
//
// Holds: QMTECH XC7A100T core board, the bare HDMI breakout on header U4 pins
// 7-26, and a LilyGO TTGO T8 V1.7.1 (ESP32-WROVER), face up, inside the QMTECH's
// outline, right above the barrel jack, screwed to standoffs under the lid.
// Wiring as built: short wires soldered to the T8, to U2 7-10 (SPI), U2 61 (GND),
// U2 63 (5 V) and SW1 (PROGRAM_B).
//
// Openings are sized to the connector they serve -- only the connector:
//   HDMI  plug 13.9 x 4.45 (HDMI type A)          -> 14.4 x 5.0 in the rear wall; the socket
//                                                    sits in a pocket inside, 1.2 mm behind the face
//   DC    plug sleeve 5.5 (5.5 x 2.1 barrel)       -> 6.6 round
//   USB   receptacle 7.6 x 2.6 (T8 DXF, J1)        -> 8.0 x 3.1, with a 12 x 9 pocket outside
//                                                    for the plug body (0.4 mm wall left)
//   SD    microSD card 11 x 1 mm, inserted flat from the T8's side; it sticks out
//         ~10 mm past the T8 when seated, so it passes through the front wall
//                                                 -> 11.6 x 1.8 slot
//
// Frame: origin = the QMTECH board's corner at the U4 edge / pin-1 end, on the
// top surface of the PCB.  X runs along the headers (pin 1 -> pin 64), Y runs
// from the U4 edge (rear, HDMI) to the U2 edge (front), Z is up.
//
// Sources for every number are in README.md next to this file.  Values marked
// GUESS are not measured -- print part="hdmi_fit_test" before the real thing.
// No JTAG opening: not needed (J1 also sits under the HDMI breakout).
//
//   openscad -D 'part="base"' -o base.stl console_case.scad
//
part = "assembly";   // assembly | exploded | closed | open | section_x | section_y
                     // base | base_print | lid | lid_print | hdmi_fit_test

$fn = 40;
e = 0.01;

// ------------------------------------------------------------------ QMTECH
bw = 84.1;  bd = 67.1;  bt = 1.6;           // manual fig. 2-1
function col_x(c) = 2.33 + 2.54 * c;         // header column c = 0..31
function pin_x(p) = col_x(floor((p - 1) / 2));
u4_y = [1.85, 4.39];                         // [odd row, even row]
u2_y = [62.91, 65.45];                       // [odd row, even row]
function u2_pin_y(p) = (p % 2 == 1) ? u2_y[0] : u2_y[1];
male_plastic = 2.5;  male_pin = 6.0;         // U2: male pins, pointing up
female_h = 8.5;                              // U4: female sockets, pointing up
dupont_h = 14.0;                             // crimp housing height above header plastic
j1_x = 2.33;  j1_y0 = 8.4;                   // JTAG J1, 6 pins running +Y
jack_y = 50.9;  jack_z = 6.5;  jack_w = 9.3;  jack_h = 11;  jack_l = 14.9;  // JP1, DC-050

// FPGA package (for the preview and the vent field)
fpga = [26.4, 18.9, 52.9 - 26.4];            // x0, y-from-U2-edge, size

// ------------------------------------------------- HDMI breakout (GUESS)
// The user's breakout (photo 2026-10-04, sizes 2026-10-09): PCB 39 x 20 mm, the 2x10
// header running along the 39 mm length, the socket on top at the opposite long edge,
// sticking out ~10 mm past it.  On U4 pins 7-26, turned so the socket points out the
// BACK; HDMI's odd pins (the row farther from the socket) sit on U4's even row.
hb_l       = 39;                             // breakout length (X), along the header
hb_w       = 20;                             // breakout depth (Y)
hb_edge    = 2.5;                            // GUESS header row to the PCB's front edge
hdmi_x     = (pin_x(7) + pin_x(26)) / 2;     // header centre = socket centre (GUESS: centred)
hb_y1      = u4_y[1] + hb_edge;              // front edge of the breakout
hb_y0      = hb_y1 - hb_w;                   // back edge, where the socket sits
hb_z0      = female_h + male_plastic;        // PCB bottom: socket header + pin plastic
hb_t       = 1.6;
hs_w = 15.2;  hs_h = 6.0;  hs_d = 11.5;      // HDMI-A receptacle shell
hs_out     = 10;                             // the socket sticks out this far past the PCB
hdmi_mouth_y = hb_y0 - hs_out;
hdmi_mouth_z = hb_z0 + hb_t + hs_h / 2;      // socket on top of the breakout (photo)

// ------------------------------------------------- LilyGO T8 V1.7.1 (DXF)
// From LilyGO's T8_V1.7.dxf (local x across the board, y along it, y = 0 at the
// USB end, top view).
t8_w = 25.98;  t8_l = 61.65;  t8_t = 1.6;
t8_holes = [[2.35, 59.40], [23.86, 59.35], [23.99, 2.00]];   // M2
t8_row_r = 24.51;  t8_row_l = 1.63;
function t8_pin_ly(n) = 54.89 - 2.54 * (n - 1);              // header pin n, 1 = antenna end
t8_usb_lx = 16.64;  t8_usb_w = 7.60;  t8_usb_h = 2.6;  t8_usb_over = 0.36;   // J1 USB-MICRO-DIP
t8_sd = [[20.87, 5.58], [25.69, 16.60]];    // J4 TF-CKT01-009D: small holder at the right edge, top side
t8_sd_h = 1.8;                              // holder height (preview)
t8_card_z = 0.9;                            // card centre above the T8's top surface
t8_card_out = 10;                           // a seated card sticks out this far past the T8's edge
// Placement: face up, turned 90 deg -- antenna to the left, USB end on the QMTECH's
// right edge just in front of the barrel jack, card side on the QMTECH's front edge
// so the card sticks out through the front wall.  Inside the QMTECH's outline.
t8_xu = bw - t8_usb_over;                   // global X of the USB end: receptacle face on the board edge
t8_y0 = bd - t8_w;                          // card side flush with the board's front edge
t8_zb = 13.0;                               // T8 underside: the jack is 11 tall, USB legs poke ~1 mm below
function t8_g(p) = [t8_xu - p[1], t8_y0 + p[0]];
t8_pad_y = t8_y0 + t8_row_r;                // front header row, global Y
function t8_pad_x(n) = t8_xu - t8_pin_ly(n);

// ---------------------------------------------------------------- the case
clr     = 0.5;          // board to wall
wall    = 2.4;
floor_t = 2.0;
top_t   = 2.2;
under   = 4.0;          // board underside to floor (pin stubs, 0402s)
z_floor = -bt - under;
z_split = 12.0;         // base / lid joint
z_lid   = 19.5;         // underside of the lid's top plate: over the HDMI socket and the T8's parts
post_d = 7.5;           // screw posts, inside the box
cx0 = -clr - post_d;  cx1 = bw + clr;     // left: room for the two left posts beside the board
cy0 = hdmi_mouth_y + 1.2;   // rear wall inner face: the socket mouth sits in the wall, 1.2 behind its face
cy1 = bd + clr;          // front wall right at the board
lip_t = 1.2;  lip_h = 2.5;  lip_clr = 0.25;

// Screw posts (M3), inside the box: both back corners, and front-left in the margin
// beside the board.  Front-right has no room (board, jack and card), the lid lip holds it.
post_in = post_d / 2 - 0.8;   // centre offset from the walls: posts sink 0.8 mm into them, merging solidly
function posts() = [[cx0 + post_in, cy0 + post_in], [cx1 - post_in, cy0 + post_in],
                    [cx0 + post_in, cy1 - post_in]];

module inner2d() { translate([cx0, cy0]) square([cx1 - cx0, cy1 - cy0]); }
module outer2d() { offset(r = wall) inner2d(); }
module box(p0, p1) { translate(p0) cube([p1[0] - p0[0], p1[1] - p0[1], p1[2] - p0[2]]); }

// ---------------------------------------- openings shared by base and lid
module cutouts() {
    // HDMI: the plug opening through the rear wall ...
    box([hdmi_x - 7.2, cy0 - wall - 1, hdmi_mouth_z - 2.5], [hdmi_x + 7.2, cy0 + 1, hdmi_mouth_z + 2.5]);
    // ... and, from the inside only, a pocket for the socket shell
    box([hdmi_x - hs_w / 2 - 0.3, hdmi_mouth_y - 0.01, hdmi_mouth_z - hs_h / 2 - 0.3], [hdmi_x + hs_w / 2 + 0.3, cy0 + 1, hdmi_mouth_z + hs_h / 2 + 0.3]);
    // DC barrel: the 5.5 mm sleeve (9.5 mm long: it seats through the wall)
    translate([cx1 - 1, jack_y, jack_z]) rotate([0, 90, 0]) cylinder(d = 6.6, h = wall + 3, $fn = 48);
    // T8 micro-USB: the receptacle, and outside a pocket for the plug body that
    // leaves 0.4 mm of wall, so the plug goes all the way in
    uy = t8_y0 + t8_usb_lx;  uz = t8_zb + t8_t + t8_usb_h / 2;
    box([cx1 - 1, uy - (t8_usb_w + 0.4) / 2, uz - (t8_usb_h + 0.5) / 2], [cx1 + wall + 1, uy + (t8_usb_w + 0.4) / 2, uz + (t8_usb_h + 0.5) / 2]);
    box([cx1 + 0.4, uy - 6, uz - 4.5], [cx1 + wall + 1, uy + 6, uz + 4.5]);
    // microSD card through the front wall
    cx = t8_xu - (t8_sd[0][1] + t8_sd[1][1]) / 2;  cz = t8_zb + t8_t + t8_card_z;
    box([cx - 5.8, cy1 - 1, cz - 0.9], [cx + 5.8, cy1 + wall + 1, cz + 0.9]);
}

// --------------------------------------------------------------------- base
module base() {
    difference() {
        union() {
            difference() {
                translate([0, 0, z_floor - floor_t]) linear_extrude(z_split - z_floor + floor_t) outer2d();
                translate([0, 0, z_floor]) linear_extrude(100) inner2d();
            }
            // ledges under the two short edges (clear of the header pin stubs)
            for (x = [[-2, 1.0], [bw - 1.0, cx1]])
                box([x[0] - e, 6.5, z_floor - e], [x[1], 60.5, -bt]);
            // screw posts
            for (p = posts()) translate([p[0], p[1], z_floor - e]) cylinder(d = post_d, h = z_split - z_floor + e);
            // left stop: the board's left edge (the left wall is out past the posts)
            box([-2, 6.5, z_floor - e], [-clr / 2, 60.5, 1.5]);
            // corner stops: fix the board in Y
            for (x = [[-2, 1.0], [bw - 1.0, cx1]]) {
                box([x[0] - e, -2.4,  z_floor - e], [x[1], -clr / 2,     1.5]);
                box([x[0] - e, bd + clr / 2, z_floor - e], [x[1], bd + 2.4, 1.5]);
            }
        }
        cutouts();
        // M3 self-tapping pilots in the screw posts
        for (p = posts()) translate([p[0], p[1], z_split - 10]) cylinder(d = 2.5, h = 11);
        // intake slots in the floor behind the board
        for (x = [44 : 4 : 72]) box([x, cy0 + 1.2, z_floor - floor_t - 1], [x + 2, -2.8, z_floor + 1]);
        // pockets for stick-on rubber feet
        for (p = [[cx0 + 14, cy0 + 7], [cx1 - 14, cy0 + 7], [cx0 + 14, cy1 - 7], [cx1 - 7, cy1 - 7]])
            translate([p[0], p[1], z_floor - floor_t - 1]) cylinder(d = 10.5, h = 1.8);
    }
}

// ---------------------------------------------------------------------- lid
module lid() {
    difference() {
        union() {
            difference() {
                translate([0, 0, z_split]) linear_extrude(z_lid + top_t - z_split) outer2d();
                translate([0, 0, z_split - e]) linear_extrude(z_lid - z_split + e) inner2d();
            }
            // locating lip that drops inside the base wall
            difference() {
                translate([0, 0, z_split - lip_h]) linear_extrude(lip_h + e) difference() {
                    offset(delta = -lip_clr) inner2d();
                    offset(delta = -lip_clr - lip_t) inner2d();
                }
                box([bw - jack_l - 1, jack_y - jack_w / 2 - 1, -1], [cx1 + 1, jack_y + jack_w / 2 + 1, jack_h + 1]);
                // the HDMI breakout's PCB reaches back to the rear wall
                box([hdmi_x - hb_l / 2 - 1, cy0 - 1, hb_z0 - 0.5], [hdmi_x + hb_l / 2 + 1, hb_y1 + 1, z_split + 1]);
                // none along the front: the wires on U2 rise right beside it
                box([cx0 - 1, cy1 - 3, -1], [cx1 + 1, cy1 + 1, z_split + 1]);
            }
            // screw posts, meeting the base's posts
            for (p = posts()) translate([p[0], p[1], z_split]) cylinder(d = post_d, h = z_lid - z_split + e);
            // T8 standoffs (M2 x 6 from below, through the T8)
            for (h = t8_holes) let (g = t8_g(h))
                translate([g[0], g[1], t8_zb + t8_t]) cylinder(d = 5, h = z_lid - t8_zb - t8_t + e);
            // hold-downs: board edges, HDMI socket top, U4 socket strip
            box([-1.2, 28, 0.3], [0.7, 40, z_lid + e]);
            box([bw - 0.7, 18, 0.3], [cx1, 32, z_lid + e]);
            box([hdmi_x - 4, hdmi_mouth_y + 3.5, hdmi_mouth_z + hs_h / 2 + 0.3],
                [hdmi_x + 4, hdmi_mouth_y + 9.5, z_lid + e]);
            box([hdmi_x + hb_l / 2 + 1.5, 2.3, female_h + 0.3], [pin_x(64) + 1, 3.9, z_lid + e]);
        }
        cutouts();
        for (h = t8_holes) let (g = t8_g(h))
            translate([g[0], g[1], t8_zb + t8_t - e]) cylinder(d = 1.7, h = 6);
        // screws: M3 x 16 from the top, heads sunk flush
        for (p = posts()) {
            translate([p[0], p[1], z_split - 1]) cylinder(d = 3.4, h = 40);
            translate([p[0], p[1], z_lid + top_t - 3.2]) cylinder(d = 6.2, h = 10);
        }
        // exhaust over the FPGA, clear of the T8's standoffs
        for (y = [14 : 4 : 30]) box([fpga[0], y, z_lid - 1], [fpga[0] + fpga[2] + 2, y + 2, z_lid + top_t + 1]);
        // side vents above the board (through the walls only)
        for (y = [22 : 4 : 50]) box([cx0 - wall - 1, y, 13.5], [cx0 + e, y + 2, 18.5]);
        for (y = [20 : 4 : 36]) box([cx1 - e, y, 13.5], [cx1 + wall + 1, y + 2, 18.5]);
        // name
        translate([(cx0 + cx1) / 2 - 6, 66, z_lid + top_t - 0.6]) rotate([0, 0, 180])
            linear_extrude(1) text("FPGA CONSOLE", size = 6, halign = "center", valign = "center",
                                   font = "Liberation Sans:style=Bold");
    }
}
// ------------------------------------------------------------------ preview
module qmtech() {
    color("darkgreen") translate([0, 0, -bt]) cube([bw, bd, bt]);
    color("dimgray") translate([fpga[0], bd - fpga[1] - fpga[2], 0]) cube([fpga[2], fpga[2], 2.5]);
    // U2: male header, U4: female header
    color("black") translate([col_x(0) - 1.27, u2_y[0] - 1.27, 0]) cube([32 * 2.54, 5.08, male_plastic]);
    for (c = [0 : 31], y = u2_y) color("gold") translate([col_x(c), y, 0]) cylinder(d = 0.64, h = male_plastic + male_pin, $fn = 8);
    color("black") translate([col_x(0) - 1.27, u4_y[0] - 1.27, 0]) cube([32 * 2.54, 5.08, female_h]);
    color("black") translate([j1_x - 1.27, j1_y0 - 1.27, 0]) cube([2.54, 6 * 2.54, male_plastic]);
    color("silver") translate([bw - jack_l, jack_y - jack_w / 2, 0]) cube([jack_l, jack_w, jack_h]);
}
module hdmi_breakout() {
    color("royalblue") translate([hdmi_x - hb_l / 2, hb_y0, hb_z0]) cube([hb_l, hb_w, hb_t]);
    color("silver") translate([hdmi_x - hs_w / 2, hdmi_mouth_y, hb_z0 + hb_t]) cube([hs_w, hs_d, hs_h]);
}
module t8_parts() {   // local coordinates: PCB, SD holder, USB
    cube([t8_w, t8_l, t8_t]);
    translate([t8_sd[0][0], t8_sd[0][1], t8_t]) cube([t8_sd[1][0] - t8_sd[0][0], t8_sd[1][1] - t8_sd[0][1], t8_sd_h]);
    translate([t8_usb_lx - t8_usb_w / 2, -t8_usb_over, t8_t]) cube([t8_usb_w, 6.06, t8_usb_h]);
}
module card_local() {   // a seated microSD card, 11 x 15 x 0.8, sticking out past the T8's edge
    cyc = (t8_sd[0][1] + t8_sd[1][1]) / 2;
    translate([t8_w + t8_card_out - 15, cyc - 5.5, t8_t + t8_card_z - 0.4]) cube([15, 11, 0.8]);
}
module t8_body() { translate([t8_xu, t8_y0, t8_zb]) rotate([0, 0, 90]) t8_parts(); }
module card() { translate([t8_xu, t8_y0, t8_zb]) rotate([0, 0, 90]) card_local(); }
module t8() {
    translate([t8_xu, t8_y0, t8_zb]) rotate([0, 0, 90]) {
        color([0.1, 0.1, 0.1]) cube([t8_w, t8_l, t8_t]);
        color("silver") translate([t8_sd[0][0], t8_sd[0][1], t8_t]) cube([t8_sd[1][0] - t8_sd[0][0], t8_sd[1][1] - t8_sd[0][1], t8_sd_h]);
        color("silver") translate([t8_usb_lx - t8_usb_w / 2, -t8_usb_over, t8_t]) cube([t8_usb_w, 6.06, t8_usb_h]);
        color("silver") translate([4, t8_l - 9, t8_t]) cube([13, 7, 1]);       // antenna
        color("dodgerblue") card_local();
    }
}
// The wiring as built: short wires soldered to the T8's pads and onto the U2 pins.
links = [ // [U2 pin, T8 front-row pin, colour]
    [ 7,  9, "yellow"],   // SCLK  <- IO18
    [ 8,  8, "green"],    // MOSI  <- IO23
    [ 9,  7, "blue"],     // MISO  -> IO19
    [10, 10, "white"],    // CS    <- IO5
    [61, 12, "black"],    // GND
    [63, 15, "red"]];     // VIN 5 V -> T8 5V
sw1 = [80.0, 11.6];       // QMTECH program button (PROGRAM_B), from the vendor drawing
module wire(pts, c) { color(c) for (i = [0 : len(pts) - 2]) hull() { translate(pts[i]) sphere(d = 1.2, $fn = 8); translate(pts[i + 1]) sphere(d = 1.2, $fn = 8); } }
module jumper_housing(x, y, ztop) { translate([x - 1.27, y - 1.27, ztop - dupont_h]) cube([2.54, 2.54, dupont_h]); }
module harness() {
    zu = male_plastic + male_pin;     // soldered at the tip of a U2 pin
    for (w = links) let (x0 = pin_x(w[0]), y0 = u2_pin_y(w[0]), x1 = t8_pad_x(w[1]))
        wire([[x0, y0, zu], [x0, y0, zu + 1.5], [x1, t8_pad_y, zu + 1.5], [x1, t8_pad_y, t8_zb]], w[2]);
    let (x1 = t8_xu - t8_pin_ly(6), y1 = t8_y0 + t8_row_l)   // IO32: 6th pin of the back row
        wire([[sw1[0], sw1[1], 1], [sw1[0], sw1[1], 9], [x1, y1, 9], [x1, y1, t8_zb]], "orange");
}
module usb_plug() {   // a micro-USB cable in the T8: metal shell, then the overmould
    uy = t8_y0 + t8_usb_lx;  uz = t8_zb + t8_t + t8_usb_h / 2;
    box([t8_xu + t8_usb_over, uy - 3.4, uz - 0.9], [t8_xu + t8_usb_over + 6.8, uy + 3.4, uz + 0.9]);
    box([t8_xu + t8_usb_over + 6.8, uy - 5.5, uz - 3.75], [cx1 + wall + 25, uy + 5.5, uz + 3.75]);
}
module dc_plug() {    // a 5.5 x 2.1 barrel plug: 9.5 mm sleeve, then the body
    translate([bw, jack_y, jack_z]) rotate([0, 90, 0]) cylinder(d = 5.5, h = 9.5);
    translate([bw + 9.5, jack_y, jack_z]) rotate([0, 90, 0]) cylinder(d = 10, h = 25);
}
module harness_body() {   // the solid parts of the wiring, for the clash check: solder joints on U2
    for (w = links) translate([pin_x(w[0]) - 1, u2_pin_y(w[0]) - 1, male_plastic + male_pin - 1]) cube([2, 2, 2]);
}

module hdmi_fit_test() {
    intersection() {
        union() { base(); lid(); }
        box([hdmi_x - 16, cy0 - wall, -50], [hdmi_x + 16, cy0 + 6, 50]);   // the wall around the opening
    }
}

module contents() { qmtech(); hdmi_breakout(); t8(); harness(); }
module section(p0, p1) { intersection() { children(); box(p0, p1); } }
big = 500;

if (part == "assembly") {
    color("lightgray") base(); contents();
    color([0.6, 0.75, 0.9, 0.35]) lid();
} else if (part == "closed") {
    color("lightgray") base(); color([0.6, 0.75, 0.9]) lid();
} else if (part == "open") {
    color("lightgray") base(); qmtech(); hdmi_breakout(); harness();
} else if (part == "exploded") {
    color("lightgray") base(); qmtech(); hdmi_breakout(); harness();
    translate([0, 0, 35]) { color([0.6, 0.75, 0.9]) lid(); t8(); }
} else if (part == "section_x") {      // cut through the HDMI socket, looking from +X
    section([-big, -big, -big], [hdmi_x, big, big]) { color("lightgray") base(); color([0.6, 0.75, 0.9]) lid(); contents(); }
} else if (part == "section_y") {      // cut through the front wire lane, looking from +Y
    section([-big, -big, -big], [big, jack_y, big]) { color("lightgray") base(); color([0.6, 0.75, 0.9]) lid(); contents(); }
} else if (part == "clash_base") intersection() { base(); union() { qmtech(); hdmi_breakout(); harness_body(); } }
else if (part == "clash_lid") intersection() { lid(); union() { qmtech(); hdmi_breakout(); t8_body(); harness_body(); } }
else if (part == "clash_parts") intersection() { t8_body(); harness_body(); }
else if (part == "clash_usb") intersection() { usb_plug(); union() { harness_body(); qmtech(); base(); lid(); dc_plug(); } }
else if (part == "clash_dc") intersection() { dc_plug(); union() { base(); lid(); } }
else if (part == "clash_card") intersection() { card(); union() { base(); lid(); qmtech(); harness_body(); } }
else if (part == "base") base();
else if (part == "base_print") translate([0, 0, floor_t - z_floor]) base();
else if (part == "lid") lid();
else if (part == "lid_print") rotate([180, 0, 0]) translate([0, 0, -(z_lid + top_t)]) lid();
else if (part == "hdmi_fit_test") rotate([90, 0, 0]) translate([0, -(cy0 - wall), 0]) hdmi_fit_test();
// an HDMI-A plug fully in: 13.9 x 4.45 shell, 11.5 long, 9.5 of it in the socket, then a 21 x 11 body
module hdmi_plug() {
    box([hdmi_x - 6.95, hdmi_mouth_y - 2.0, hdmi_mouth_z - 2.225], [hdmi_x + 6.95, hdmi_mouth_y + 9.5, hdmi_mouth_z + 2.225]);
    box([hdmi_x - 10.5, hdmi_mouth_y - 40, hdmi_mouth_z - 5.5], [hdmi_x + 10.5, hdmi_mouth_y - 2.0, hdmi_mouth_z + 5.5]);
}
if (part == "clash_hdmi") intersection() { hdmi_plug(); union() { base(); lid(); } }
// test: the wall material where the HDMI plug goes through (should be empty)
if (part == "test_hdmi_hole") intersection() { union() { base(); lid(); } box([hdmi_x - 6, cy0 - wall - 0.5, hdmi_mouth_z - 1.8], [hdmi_x + 6, cy0 + 0.5, hdmi_mouth_z + 1.8]); }
