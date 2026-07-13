//! Demo module for zega Code Bubbles — real Rust source.

fn main() {
    let p = Point::new(3, 4);
    println!("len={}", p.length());
    run_app();
}

fn run_app() {
    let _cfg = Config { verbose: true };
}

pub struct Point {
    pub x: i32,
    pub y: i32,
}

impl Point {
    pub fn new(x: i32, y: i32) -> Self {
        Self { x, y }
    }

    pub fn length(&self) -> f64 {
        ((self.x * self.x + self.y * self.y) as f64).sqrt()
    }
}

pub enum Color {
    Red,
    Green,
    Blue,
}

pub struct Config {
    pub verbose: bool,
}

pub trait Drawable {
    fn draw(&self);
}

impl Drawable for Point {
    fn draw(&self) {
        println!("point({}, {})", self.x, self.y);
    }
}
