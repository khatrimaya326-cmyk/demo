const express = require('express');
const { Pool } = require('pg');
const cors = require('cors');

const app = express();
app.use(cors());
app.use(express.json());

const pool = new Pool({
  host:     process.env.DB_HOST,
  port:     process.env.DB_PORT || 5432,
  database: process.env.DB_NAME || 'appdb',
  user:     process.env.DB_USER || 'appuser',
  password: process.env.DB_PASSWORD,
});

app.get('/health', (req, res) => res.json({ status: 'ok' }));

app.get('/api/items', async (req, res) => {
  const { rows } = await pool.query('SELECT * FROM items ORDER BY id DESC LIMIT 50');
  res.json(rows);
});

app.post('/api/items', async (req, res) => {
  const { name } = req.body;
  const { rows } = await pool.query(
    'INSERT INTO items(name) VALUES($1) RETURNING *', [name]
  );
  res.status(201).json(rows[0]);
});

const PORT = process.env.PORT || 3000;
app.listen(PORT, () => console.log(`Backend running on port ${PORT}`));
