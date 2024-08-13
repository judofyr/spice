pub struct Node {
    value: i64,
    left: Option<Box<Node>>,
    right: Option<Box<Node>>,
}

pub fn make_balanced_tree(from: i64, to: i64) -> Node {
    let value = from + (to - from) / 2;
    Node {
        value,
        left: (value > from).then(|| Box::new(make_balanced_tree(from, value - 1))),
        right: (value < to).then(|| Box::new(make_balanced_tree(value + 1, to))),
    }
}

pub fn sum(node: &Node) -> i64 {
    match (&node.left, &node.right) {
        (Some(left), Some(right)) => node.value + sum(left) + sum(right),
        (Some(child), _) | (_, Some(child)) => node.value + sum(child),
        (None, None) => node.value,
    }
}

pub fn sum_rayon(pool: &rayon::ThreadPool, node: &Node) -> i64 {
    match (&node.left, &node.right) {
        (Some(left), Some(right)) => {
            let (left, right) = pool.join(|| sum_rayon(pool, left), || sum_rayon(pool, right));
            node.value + left + right
        }
        (Some(child), _) | (_, Some(child)) => node.value + sum_rayon(pool, child),
        (None, None) => node.value,
    }
}
