/**
 * ตารางหยุดงานร้านเรา — ฐานข้อมูลบน Google Sheet
 * วางโค้ดนี้ใน Apps Script ของ Google Sheet แล้ว Deploy เป็น Web App
 * (ดูวิธีทำในไฟล์ คู่มือติดตั้ง.md)
 */

var SHEET_NAME = 'Leaves';
var MAX_PER_DAY = 3;

/**
 * ตรวจว่าเป็นแอดมิน (หัวหน้า) ไหม — ใช้เฉพาะตอน "เพิ่มเกิน 3 คน/วัน" เท่านั้น
 * รหัสเก็บใน Script Properties (ไม่ฝังในโค้ด public)
 * ตั้งรหัส: Apps Script → Project Settings (⚙️) → Script Properties →
 *   Add property → Property: ADMIN_KEY | Value: <รหัสลับ> → Save
 */
function isAdmin(key) {
  var k = PropertiesService.getScriptProperties().getProperty('ADMIN_KEY');
  return !!(k && key && String(key) === k);
}

function getSheet() {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var sh = ss.getSheetByName(SHEET_NAME);
  if (!sh) {
    sh = ss.insertSheet(SHEET_NAME);
    sh.appendRow(['date', 'name', 'timestamp']);
  }
  // บังคับคอลัมน์วันที่เป็น "ข้อความ" ไม่ให้ Google แปลง 2026-07-10 เป็นวันที่อัตโนมัติ
  sh.getRange('A2:A').setNumberFormat('@');
  return sh;
}

/** แปลงค่าในช่องวันที่ให้เป็นข้อความ yyyy-MM-dd เสมอ (เผื่อแถวเก่าที่เป็นชนิดวันที่) */
function normDate(v) {
  if (v instanceof Date) {
    return Utilities.formatDate(v, Session.getScriptTimeZone(), 'yyyy-MM-dd');
  }
  return String(v).trim();
}

var THAI_MON = ['ม.ค.','ก.พ.','มี.ค.','เม.ย.','พ.ค.','มิ.ย.','ก.ค.','ส.ค.','ก.ย.','ต.ค.','พ.ย.','ธ.ค.'];

/** แปลงค่าเวลาที่บันทึกให้เป็นข้อความไทยพร้อมแสดง เช่น "6 ก.ค. 08:30" (ทนทานทุกชนิดค่า) */
function fmtTs(ts, tz) {
  var d = null;
  if (ts && typeof ts.getTime === 'function') d = ts;        // เป็น Date อยู่แล้ว (duck-typing กัน instanceof เพี้ยน)
  else if (typeof ts === 'number' && ts > 0) d = new Date(Math.round((ts - 25569) * 86400000)); // serial ของชีต
  else if (ts) { var t = new Date(ts); if (!isNaN(t.getTime())) d = t; }  // เป็นข้อความ
  if (!d || isNaN(d.getTime())) return "";
  var day = Utilities.formatDate(d, tz, "d");
  var mon = parseInt(Utilities.formatDate(d, tz, "M"), 10) - 1;
  var hm = Utilities.formatDate(d, tz, "HH:mm");
  return day + " " + THAI_MON[mon] + " " + hm;
}

/** อ่านข้อมูลทั้งหมด -> { "2026-07-04": [{name:"สมชาย", ts:"6 ก.ค. 08:30"}, ...], ... } */
function readAll() {
  var sh = getSheet();
  var rows = sh.getDataRange().getValues();
  var tz = Session.getScriptTimeZone();
  var data = {};
  for (var i = 1; i < rows.length; i++) {
    var date = normDate(rows[i][0]);
    var name = String(rows[i][1]).trim();
    if (!date || !name) continue;
    if (!data[date]) data[date] = [];
    data[date].push({ name: name, ts: fmtTs(rows[i][2], tz) });
  }
  return data;
}

function namesForDate(sh, date) {
  var rows = sh.getDataRange().getValues();
  var names = [];
  for (var i = 1; i < rows.length; i++) {
    if (normDate(rows[i][0]) === date) names.push(String(rows[i][1]).trim());
  }
  return names;
}

/* ---------- วันห้ามหยุด (Blocked) ---------- */
var BLOCK_SHEET = 'Blocked';
function getBlockedSheet() {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var sh = ss.getSheetByName(BLOCK_SHEET);
  if (!sh) { sh = ss.insertSheet(BLOCK_SHEET); sh.appendRow(['date']); }
  sh.getRange('A2:A').setNumberFormat('@');
  return sh;
}
function readBlocked() {
  var sh = getBlockedSheet();
  var rows = sh.getDataRange().getValues();
  var out = [];
  for (var i = 1; i < rows.length; i++) {
    var d = normDate(rows[i][0]);
    if (d && out.indexOf(d) < 0) out.push(d);
  }
  return out;
}
function isBlockedDate(date) { return readBlocked().indexOf(date) >= 0; }
function addBlocked(date) {
  var sh = getBlockedSheet();
  if (!isBlockedDate(date)) {
    sh.appendRow([date]);
    var r = sh.getLastRow();
    sh.getRange(r, 1).setNumberFormat('@').setValue(date);
  }
}
function removeBlocked(date) {
  var sh = getBlockedSheet();
  var rows = sh.getDataRange().getValues();
  for (var i = rows.length - 1; i >= 1; i--) {
    if (normDate(rows[i][0]) === date) sh.deleteRow(i + 1);
  }
}
/** ตอบกลับพร้อมข้อมูลตาราง + วันห้ามหยุด */
function resp(obj) { obj.data = readAll(); obj.blocked = readBlocked(); return json(obj); }

/** GET: ส่งข้อมูลทั้งหมดกลับไป (?debug=1 เพื่อดูชนิดค่าจริงในแถวล่าสุด) */
function doGet(e) {
  if (e && e.parameter && e.parameter.debug) {
    var sh = getSheet();
    var rows = sh.getDataRange().getValues();
    var last = rows[rows.length - 1];
    return json({
      ok: true, debug: true, rowCount: rows.length,
      tz: Session.getScriptTimeZone(),
      lastRow: last,
      types: last.map(function (x) { return (x && typeof x.getTime === 'function') ? 'Date' : typeof x; })
    });
  }
  return resp({ ok: true });
}

/** POST: เพิ่ม/ลบชื่อ (เช็คโควตา 3 คน/วัน ที่ฝั่งเซิร์ฟเวอร์) */
function doPost(e) {
  var lock = LockService.getScriptLock();
  lock.waitLock(20000); // กันคนหลายคนบันทึกชนกัน
  try {
    var req = JSON.parse(e.postData.contents);
    var action = req.action;
    var date = String(req.date || '').trim();
    var name = String(req.name || '').trim();
    var sh = getSheet();

    var admin = isAdmin(req.key);

    // ตรวจรหัสแอดมิน (ให้หน้าเว็บรู้ว่าปลดล็อก "เพิ่มเกิน 3 / ตั้งวันห้ามหยุด" ได้ไหม)
    if (action === 'auth') {
      return json({ ok: true, admin: admin });
    }

    // ตั้ง/ยกเลิก วันห้ามหยุด (เฉพาะแอดมิน)
    if (action === 'block' || action === 'unblock') {
      if (!admin) return resp({ ok: false, error: 'forbidden' });
      if (!date) return resp({ ok: false, error: 'invalid' });
      if (action === 'block') addBlocked(date); else removeBlocked(date);
      return resp({ ok: true });
    }

    if (action === 'add') {
      if (!date || !name) return resp({ ok: false, error: 'invalid' });
      if (isBlockedDate(date)) return resp({ ok: false, error: 'blocked' });  // วันห้ามหยุด ลงไม่ได้
      var current = namesForDate(sh, date);
      var force = req.force && admin;   // แอดมินเท่านั้นที่เพิ่มเกิน 3 คนได้
      if (!force && current.length >= MAX_PER_DAY) {
        return resp({ ok: false, error: 'full' });
      }
      var dup = current.some(function (n) { return n.toLowerCase() === name.toLowerCase(); });
      if (dup) return resp({ ok: false, error: 'duplicate' });
      // เขียนแถวใหม่ แล้วบังคับช่องวันที่ให้เป็น "ข้อความ" ชัดเจน
      // (กันทั้งการแปลงเป็นวันที่ และปัญหาโซนเวลา)
      sh.appendRow([date, name, new Date()]);
      var r = sh.getLastRow();
      sh.getRange(r, 1).setNumberFormat('@').setValue(date);
      return resp({ ok: true });
    }

    if (action === 'remove') {
      // ทุกคนลบได้
      var rows = sh.getDataRange().getValues();
      for (var i = rows.length - 1; i >= 1; i--) {
        if (normDate(rows[i][0]) === date &&
            String(rows[i][1]).trim().toLowerCase() === name.toLowerCase()) {
          sh.deleteRow(i + 1);
          break;
        }
      }
      return resp({ ok: true });
    }

    return resp({ ok: false, error: 'unknown_action' });
  } catch (err) {
    return json({ ok: false, error: String(err) });
  } finally {
    lock.releaseLock();
  }
}

function json(obj) {
  return ContentService
    .createTextOutput(JSON.stringify(obj))
    .setMimeType(ContentService.MimeType.JSON);
}
