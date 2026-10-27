use fastly::http::{Request, Response};
use fastly::Error;

#[fastly::main]
fn main(req: Request) -> Result<Response, Error> {
    // Minimal: return a health response. Full evaluation core port pending.
    Ok(Response::from_status(200).with_body("doppio fastly compute ok"))
}