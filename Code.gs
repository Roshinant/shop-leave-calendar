/**
 * ตารางหยุดงานร้านเรา — ฐานข้อมูลบน Google Sheet
 * วางโค้ดนี้ใน Apps Script ของ Google Sheet แล้ว Deploy เป็น Web App
 * (ดูวิธีทำในไฟล์ คู่มือติดตั้ง.md)
 */

var SHEET_NAME = 'Leaves';
var MAX_PER_DAY = 3;

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

/** อ่านข้อมูลทั้งหมด -> { "2026-07-04": ["สมชาย","สมหญิง"], ... } */
function readAll() {
  var sh = getSheet();
  var rows = sh.getDataRange().getValues();
  var data = {};
  for (var i = 1; i < rows.length; i++) {
    var date = normDate(rows[i][0]);
    var name = String(rows[i][1]).trim();
    if (!date || !name) continue;
    if (!data[date]) data[date] = [];
    data[date].push(name);
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

/** GET: ส่งข้อมูลทั้งหมดกลับไป */
function doGet(e) {
  return json({ ok: true, data: readAll() });
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

    if (action === 'add') {
      if (!date || !name) return json({ ok: false, error: 'invalid', data: readAll() });
      var current = namesForDate(sh, date);
      if (current.length >= MAX_PER_DAY) {
        return json({ ok: false, error: 'full', data: readAll() });
      }
      var dup = current.some(function (n) { return n.toLowerCase() === name.toLowerCase(); });
      if (dup) return json({ ok: false, error: 'duplicate', data: readAll() });
      // เขียนแถวใหม่ แล้วบังคับช่องวันที่ให้เป็น "ข้อความ" ชัดเจน
      // (กันทั้งการแปลงเป็นวันที่ และปัญหาโซนเวลา)
      sh.appendRow([date, name, new Date()]);
      var r = sh.getLastRow();
      sh.getRange(r, 1).setNumberFormat('@').setValue(date);
      return json({ ok: true, data: readAll() });
    }

    if (action === 'remove') {
      var rows = sh.getDataRange().getValues();
      for (var i = rows.length - 1; i >= 1; i--) {
        if (normDate(rows[i][0]) === date &&
            String(rows[i][1]).trim().toLowerCase() === name.toLowerCase()) {
          sh.deleteRow(i + 1);
          break;
        }
      }
      return json({ ok: true, data: readAll() });
    }

    return json({ ok: false, error: 'unknown_action', data: readAll() });
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
