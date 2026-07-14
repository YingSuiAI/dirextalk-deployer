export class ConnectionStackV2Error extends Error {
  constructor(code, message, statusCode = 400) {
    super(message);
    this.name = "ConnectionStackV2Error";
    this.code = code;
    this.statusCode = statusCode;
  }
}
