Path C for dummies lol

Here is the complete, chronological step-by-step lifecycle of the token from generation inside the workspace up to the final sealing of the memory map and cookie on the proxy server.

## Step 1: Token Generation (Inside the Coder Workspace Container)
The developer executes the native Linux Go binary ./sync-prep inside their workspace terminal with zero manual parameters.
 1. **Internal Key Fetch:** The tool handles authentication via the workspace's local environment variables and performs a local REST call to the running Coder agent:
   ```http
   GET http://localhost:8080/api/v2/workspaceagents/me/gitsshkey
   
   ```
 2. **Standard Library Key Parsing:** The tool reads the JSON response, isolates the private key PEM string, and natively parses it using the standard library's crypto/ed25519 engine.
 3. **Inner Metadata Block Construction:** The tool extracts the raw ENC(...) ciphertext from the local $env:ANTHROPIC_API_KEY and captures a frozen UTC timestamp. It formats them into a clean inner JSON structure:
   ```json
   {
     "ciphertext": "ENC(vault:v1:global_anthropic_key)",
     "timestamp": "2026-06-19T08:09:04Z"
   }
   
   ```
 4. **The Inner Base64 Encoding:** This inner JSON object is marshaled into bytes and converted into a standard Base64 string (InnerPayload).
 5. **Cryptographic Signing:** The tool computes the asymmetric signature directly over that InnerPayload string using the private key:
   ```go
   signatureBytes := ed25519.Sign(privateKey, []byte(InnerPayload))
   
   ```
 6. **The Final Outer Envelope Assembly:** The InnerPayload string and the base64-encoded signature are combined into a final outer JSON block:
   ```json
   {
     "payload": "eyJDY2hlcnRleHQiOiJFTkMoLi4uKSIsIlRpbWVzdGFtcCI6IjIwMjYtMDYtMTlUIi99...",
     "signature": "AAAAgSdf89sk...=="
   }
   
   ```
 7. **The One-Time Password (OTP) Output:** The entire outer block is converted into a single, cohesive Base64 string and printed to the terminal screen.

## Step 2: Workstation Registration Handshake (On the Laptop)
The developer copies the printed OTP string, opens a PowerShell/CMD terminal on their physical laptop, and runs the Windows binary.
 1. **Local Machine Identification:** The local Windows utility execution automatically captures its own physical OS hostname natively (e.g., LT-WALT-01).
 2. **Network Transmission:** The tool packages the machine name and the unaltered workspace OTP token together and posts it via HTTPS over the corporate network/VPN to the Go Proxy:
   ```json
   POST /api/v1/sync
   {
     "machine_name": "LT-WALT-01",
     "otp_payload": "eyJwYXlsb2FkIjoiZXl..."
   }
   
   ```
## Step 3: Decoupling and Verification (On the Go Proxy Server)
The proxy intercepts the request on its /api/v1/sync endpoint and processes it using only native standard library tools.
 1. **Identity Resolution:** The proxy maps the incoming machine_name (LT-WALT-01) against its local internal configuration map to resolve the unique corporate owner identity (e.g., walter@corporate.com).
 2. **Public Key Retrieval:** The proxy queries the central Coder control plane API to fetch the registered, verified public SSH keys belonging to walter@corporate.com.
 3. **Envelope Unwrapping:** The proxy decodes the outer otp_payload string to separate the inner payload from the signature.
 4. **Native Signature Verification:** The proxy runs the public key over the payload:
   ```go
   isValid := ed25519.Verify(pubKeyFromCoder, []byte(incoming.Payload), incoming.SignatureBytes)
   
   ```
   *If someone tampered with the payload or tried to use a fake key, the verification fails instantly right here.*
 5. **Parameter Introspection:** Because the signature is valid, the proxy decodes the inner payload base64 string back into raw text, giving the proxy complete visibility into the parameters:
   * It checks that the Timestamp is fresh (under 5 minutes old) to block replay attacks.
   * It extracts the raw ENC(...) ciphertext string directly.
## Step 4: Seeding and Sealing the Session Tables
Now that authenticity and ownership are mathematically proven, the proxy securely anchors the session.
 1. **Hashing the Ciphertext:** The proxy runs a SHA256 hash on the extracted ENC(...) string to get a fixed-length 32-byte identifier (CiphertextHash).
 2. **Sealing the RAM Map Entry:** The proxy captures the source network IP address directly from the xff header and commits a new session row into its volatile internal memory table using the machine_name as the primary key:
   ```go
   laptopRegistry.sessions["LT-WALT-01"] = &LaptopSession{
       MachineName:    "LT-WALT-01",
       LockedClientIP: "198.51.100.42",               // Captured from TCP network layer
       CiphertextHash: "8a3f91b...",                  // sha256(extractedCiphertext)
       DecryptedKey:   "",                            // LEFT BLANK until first Claude call
       Expiration:     time.Now().Add(24 * time.Hour),
   }
   
   ```
 3. **Generating the Sealed State Cookie:** The proxy packs the metadata parameters (MachineName, LockedClientIP, CiphertextHash, Expiration) into a micro-JSON structure. It encrypts this structure using its secret internal cluster key via AES-GCM (SERVER_MASTER_KEY).
 4. **The Response:** This encrypted token string is sent back to the laptop as the X-Session-State parameter.
The sync loop is now complete. The workstation's network location is locked down, and the proxy is armed to execute microsecond validation on the hot path.

(script example for otp generation) 

package main

import (
"crypto/ed25519"
"crypto/x509"
"encoding/base64"
"encoding/json"
"encoding/pem"
"fmt"
"io"
"log"
"net/http"
"os"
"time"
)

type CoderKeyResponse struct {
PrivateKey string `json:"private_key"`
PublicKey  string `json:"public_key"`
}

type InnerPayload struct {
Ciphertext string `json:"ciphertext"`
Timestamp  string `json:"timestamp"`
}

type OuterOTP struct {
Payload   string `json:"payload"`   // Base64 of InnerPayload JSON
Signature string `json:"signature"` // Base64 of Ed25519 signature
}

func main() {
// 1. Grab the global Anthropic ciphertext envelope from the workspace environment
ciphertext := os.Getenv("ANTHROPIC_API_KEY")
if ciphertext == "" {
log.Fatal("❌ Error: ANTHROPIC_API_KEY environment variable is not set.")
}

// 2. Query the internal Coder REST API for the agent's Git SSH private key
// In Coder, the CODER_SESSION_TOKEN is natively present in the workspace agent environment
sessionToken := os.Getenv("CODER_SESSION_TOKEN")
req, _ := http.NewRequest("GET", "http://localhost:8080/api/v2/workspaceagents/me/gitsshkey", nil)
req.Header.Set("Accept", "application/json")
if sessionToken != "" {
req.Header.Set("Coder-Session-Token", sessionToken)
}

client := &http.Client{Timeout: 5 * time.Second}
resp, err := client.Do(req)
if err != nil {
log.Fatalf("❌ Error: Failed to connect to Coder agent API: %v", err)
}
defer resp.Body.Close()

var keyData CoderKeyResponse
if err := json.NewDecoder(resp.Body).Decode(&keyData); err != nil {
log.Fatalf("❌ Error: Failed to decode Coder key payload: %v", err)
}

// 3. Parse the PEM private key natively using standard library
block, _ := pem.Decode([]byte(keyData.PrivateKey))
if block == nil {
log.Fatal("❌ Error: Failed to decode PEM block from Coder private key.")
}
rawPrivKey, err := x509.ParsePKCS8PrivateKey(block.Bytes)
if err != nil {
log.Fatalf("❌ Error: Failed to parse PKCS8 private key: %v", err)
}
privateKey, ok := rawPrivKey.(ed25519.PrivateKey)
if !ok {
log.Fatal("❌ Error: Key returned by Coder is not a valid Ed25519 key.")
}

// 4. Construct and Base64 encode the inner parameter payload
inner := InnerPayload{
Ciphertext: ciphertext,
Timestamp:  time.Now().UTC().Format(time.RFC3339),
}
innerJSON, _ := json.Marshal(inner)
innerBase64 := base64.StdEncoding.EncodeToString(innerJSON)

// 5. Compute the native Ed25519 cryptographic signature over the base64 string
sigBytes := ed25519.Sign(privateKey, []byte(innerBase64))
sigBase64 := base64.StdEncoding.EncodeToString(sigBytes)

// 6. Build the outer OTP package and encode the entire block to a single string
outer := OuterOTP{
Payload:   innerBase64,
Signature: sigBase64,
}
outerJSON, _ := json.Marshal(outer)
finalOTPToken := base64.StdEncoding.EncodeToString(outerJSON)

// 7. Present clean execution block to developer
fmt.Println("\n==========================================================================")
fmt.Println("🔑 ONE-TIME SYNC TOKEN GENERATED SUCCESSFULLY (NATIVE GO)")
fmt.Println("==========================================================================\n")
fmt.Println("Copy the token block below and pass it to your local laptop client:")
fmt.Printf("\nsync-ip.exe -otp %s\n", finalOTPToken)
fmt.Println("\n==========================================================================")
}
