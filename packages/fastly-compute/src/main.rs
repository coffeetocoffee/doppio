mod eval;

use fastly::http::{Request, Response};
use fastly::Error;

#[fastly::main]
fn main(req: Request) -> Result<Response, Error> {
    let body = "doppio fastly compute ok";
    Ok(Response::from_status(200).with_body(body))
}

#[cfg(test)]
mod tests {
    use super::eval;
    #[test]
    fn bucket_deterministic() {
        let b1 = eval::bucket("f", "u1");
        let b2 = eval::bucket("f", "u1");
        assert_eq!(b1, b2);
    }
    #[test]
    fn rollout_bounds() {
        assert!(eval::in_rollout("f", "u1", 100));
        assert!(!eval::in_rollout("f", "u1", 0));
    }
}