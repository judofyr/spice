pub struct Node {
    value: i64,
    left: Option<Box<Node>>,
    right: Option<Box<Node>>,
}

impl Node {
    pub fn make_balanced_tree(from: i64, to: i64) -> Self {
        let value = from + (to - from) / 2;
        Node {
            value,
            left: (value > from).then(|| Self::make_balanced_tree(from, value - 1).into()),
            right: (value < to).then(|| Self::make_balanced_tree(value + 1, to).into()),
        }
    }

    pub fn sum(&self) -> i64 {
        match (&self.left, &self.right) {
            (Some(left), Some(right)) => self.value + left.sum() + right.sum(),
            (Some(child), _) | (_, Some(child)) => self.value + child.sum(),
            (None, None) => self.value,
        }
    }

    pub fn sum_rayon(&self, pool: &rayon::ThreadPool) -> i64 {
        match (&self.left, &self.right) {
            (Some(left), Some(right)) => {
                let (left, right) = pool.join(|| left.sum_rayon(pool), || right.sum_rayon(pool));
                self.value + left + right
            }
            (Some(child), _) | (_, Some(child)) => self.value + child.sum_rayon(pool),
            (None, None) => self.value,
        }
    }
}
