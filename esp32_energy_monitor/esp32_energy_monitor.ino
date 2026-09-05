/************************************************************
   ESP32 + PZEM-004T-100A + LCD 20x4 I2C + FastAPI VM
   Board: ESP32 DevKit V1

   PZEM TX -> GPIO16
   PZEM RX -> GPIO17

   LCD SDA -> GPIO21
   LCD SCL -> GPIO22
 ************************************************************/

// ================= LIBRARIES =================
#include <WiFi.h>
#include <HTTPClient.h>

#include <Wire.h>
#include <LiquidCrystal_I2C.h>
#include <PZEM004Tv30.h>

// ================= WIFI =================
char ssid[] = "PLDTHOMEFIBRMTHt5";
char pass[] = "PLDTWIFI2wXtW";

// ================= VM SERVER =================
const char* serverURL = "http://35.209.250.46:8000/reading";

// ================= LCD =================
LiquidCrystal_I2C lcd(0x27, 20, 4);

// ================= PZEM =================
PZEM004Tv30 pzem(Serial2, 16, 17);

// ================= TIMER =================
unsigned long lastSendTime = 0;
const long SEND_INTERVAL   = 2000;  // 2 seconds

// =====================================================
// FUNCTION: SEND DATA TO VM
// =====================================================
void sendToVM() {

  // ===== READ PZEM VALUES =====
  float voltage   = pzem.voltage();
  float current   = pzem.current();
  float power     = pzem.power();
  float energy    = pzem.energy();
  float frequency = pzem.frequency();
  float pf        = pzem.pf();

  // ===== CHECK CONNECTION =====
  if (isnan(voltage) || isnan(current) || isnan(power) ||
      isnan(energy)  || isnan(frequency) || isnan(pf)) {

    Serial.println("❌ PZEM READ ERROR — skipping send");

    lcd.clear();
    lcd.setCursor(0, 0);
    lcd.print("PZEM ERROR");
    lcd.setCursor(0, 1);
    lcd.print("Check Wiring");

    return;
  } 

  // =================================================
  // SERIAL MONITOR
  // =================================================
  Serial.println("=========== PZEM DATA ===========");

  Serial.print("Voltage: ");
  Serial.print(voltage);
  Serial.println(" V");

  Serial.print("Current: ");
  Serial.print(current);
  Serial.println(" A");

  Serial.print("Power: ");
  Serial.print(power);
  Serial.println(" W");

  Serial.print("Energy: ");
  Serial.print(energy);
  Serial.println(" kWh");

  Serial.print("Frequency: ");
  Serial.print(frequency);
  Serial.println(" Hz");

  Serial.print("Power Factor: ");
  Serial.println(pf);

  Serial.println("=================================");

  // =================================================
  // LCD DISPLAY
  // =================================================
  lcd.clear();

  // ===== ROW 1 =====
  lcd.setCursor(0, 0);
  lcd.print("V:");
  lcd.print(voltage, 1);
  lcd.print("V");

  lcd.setCursor(11, 0);
  lcd.print("I:");
  lcd.print(current, 2);
  lcd.print("A");

  // ===== ROW 2 =====
  lcd.setCursor(0, 1);
  lcd.print("P:");
  lcd.print(power, 1);
  lcd.print("W");

  // ===== ROW 3 =====
  lcd.setCursor(0, 2);
  lcd.print("E:");
  lcd.print(energy, 3);
  lcd.print("kWh");

  // ===== ROW 4 =====
  lcd.setCursor(0, 3);
  lcd.print("F:");
  lcd.print(frequency, 1);
  lcd.print("Hz");

  lcd.setCursor(12, 3);
  lcd.print("PF:");
  lcd.print(pf, 2);

  // =================================================
  // HTTP POST TO VM
  // =================================================
  if (WiFi.status() == WL_CONNECTED) {

    HTTPClient http;
    http.begin(serverURL);
    http.addHeader("Content-Type", "application/json");

    String payload = "{";
    payload += "\"voltage\":"      + String(voltage,   2) + ",";
    payload += "\"current\":"      + String(current,   3) + ",";
    payload += "\"power\":"        + String(power,     2) + ",";
    payload += "\"cumul_kwh\":"    + String(energy,    4) + ",";
    payload += "\"frequency\":"    + String(frequency, 1) + ",";
    payload += "\"power_factor\":" + String(pf,        2);
    payload += "}";

    Serial.print("📡 Sending: ");
    Serial.println(payload);

    int responseCode = http.POST(payload);

    Serial.print("📡 HTTP Response: ");
    Serial.println(responseCode);

    if (responseCode == 200) {
      Serial.println("✅ Data sent successfully");
    } else {
      Serial.print("❌ Error sending data: ");
      Serial.println(responseCode);

      lcd.setCursor(0, 1);
      lcd.print("VM Err:");
      lcd.print(responseCode);
    }

    http.end();

  } else {
    Serial.println("❌ WiFi Disconnected — skipping send");
  }
}

// =====================================================
// SETUP
// =====================================================
void setup() {

  // ===== SERIAL MONITOR =====
  Serial.begin(115200);

  // ===== START SERIAL2 =====
  Serial2.begin(9600, SERIAL_8N1, 16, 17);

  // ===== LCD START =====
  lcd.init();
  lcd.backlight();

  lcd.setCursor(0, 0);
  lcd.print("PZEM MONITOR");

  lcd.setCursor(0, 1);
  lcd.print("Starting...");

  delay(2000);
  lcd.clear();

  // =================================================
  // CONNECT WIFI
  // =================================================
  lcd.setCursor(0, 0);
  lcd.print("Connecting WiFi");

  Serial.print("Connecting to WiFi");

  WiFi.begin(ssid, pass);

  while (WiFi.status() != WL_CONNECTED) {
    delay(500);
    Serial.print(".");
    lcd.setCursor(0, 1);
    lcd.print("Please Wait...");
  }

  // =================================================
  // WIFI CONNECTED
  // =================================================
  Serial.println("");
  Serial.println("✅ WiFi Connected");
  Serial.print("IP Address: ");
  Serial.println(WiFi.localIP());

  lcd.clear();
  lcd.setCursor(0, 0);
  lcd.print("WiFi Connected");
  lcd.setCursor(0, 1);
  lcd.print(WiFi.localIP());

  delay(2000);
  lcd.clear();
}

// =====================================================
// MAIN LOOP
// =====================================================
void loop() {
  // ── Check for manual reset command via Serial Monitor ──
  if (Serial.available()) {
    String command = Serial.readStringUntil('\n');
    command.trim();
    if (command == "reset") {
      pzem.resetEnergy();
      Serial.println("✅ Energy reset to 0");
      lcd.clear();
      lcd.setCursor(0, 0);
      lcd.print("Energy Reset!");
      lcd.setCursor(0, 1);
      lcd.print("kWh set to 0.000");
      delay(2000);
      lcd.clear();
    }
  }

  unsigned long currentTime = millis();

  if (currentTime - lastSendTime >= SEND_INTERVAL) {
    lastSendTime = currentTime;
    sendToVM();
  }
}
