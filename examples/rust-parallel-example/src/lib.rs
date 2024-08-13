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
    let mut result = node.value;
    if let Some(child) = &node.left {
        result += sum(child);
    }
    if let Some(child) = &node.right {
        result += sum(child);
    }
    result
}

pub fn sum_rayon(pool: &rayon::ThreadPool, node: &Node) -> i64 {
    if let (Some(left), Some(right)) = (&node.left, &node.right) {
        let (left_result, right_result) =
            pool.join(|| sum_rayon(pool, left), || sum_rayon(pool, right));
        return node.value + left_result + right_result;
    }

    let mut result = node.value;
    if let Some(child) = &node.left {
        result += sum_rayon(pool, child);
    }
    if let Some(child) = &node.right {
        result += sum_rayon(pool, child);
    }
    result
}
